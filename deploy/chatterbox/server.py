"""A live call's voice through Chatterbox Multilingual (Resemble AI, MIT), streamed: its own process and venv on
cappa (it pins torch and transformers apart from Aide's), on 127.0.0.1, `deploy/aide-voice.service`.

Each language speaks with the voice of a short clip, `data/voices/<lang>.wav` (10-20 s of one voice talking, in that
language: the clip's accent carries over). The speech tokens are made one at a time (25 a second of audio) and turned
into sound every EVERY tokens, a window at a time with CONTEXT tokens before it for continuity, the last HOLD tokens
kept back (they change as more come) and a short crossfade at each join: the first sound in ~0.5 s. AIDE_VOICE_SPEED
(1.15) makes it talk faster at the same pitch. Upstream switches every layer of the token model to eager attention to
watch three heads for when the line is over; here only those three layers are, and their spy is set up once: ~48
tokens a second against 31-40 (2026-11-06).

    POST /speak {"text": ..., "lang": "it"|"en"}  ->  raw PCM16, 24 kHz mono, streamed as it's made
    POST /load, POST /release (Whisper borrows the GPU), GET /health
"""

import json
import queue
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")

import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402

log = logging.getLogger("aide-voice")

PORT = int(os.environ.get("AIDE_VOICE_PORT", "8766"))
VOICES = Path(os.environ.get("AIDE_VOICES", Path(__file__).resolve().parents[2] / "data" / "voices"))
TOK = 960  # samples per speech token (24 kHz, 25 tokens a second)
FIRST, EVERY, CONTEXT, HOLD = 10, 20, 24, 3  # tokens
SOON, LOW = 6, 0.7  # with less than LOW seconds left to play, a window as soon as SOON tokens are new
STEPS = int(os.environ.get("AIDE_VOICE_STEPS", "4"))  # the decoder's flow steps (Chatterbox's 10: 0.4 s a window, 4: 0.18 s)
FADE = 480  # samples crossfaded at a join (20 ms)
SPEED = float(os.environ.get("AIDE_VOICE_SPEED", "1.15"))  # how fast it talks (the clips' pace is 1; CosyVoice's way:
# the sound's frames squeezed before they're voiced, so the pitch stays)
TAIL = int(os.environ.get("AIDE_VOICE_TAIL", "12"))  # tokens (40 ms each) a line may go on after its last words
VALID = 6561  # speech tokens at or above this are special


def give_back() -> None:
    """Hands freed memory back to the system: the model is built on the CPU before it goes to the GPU, and glibc keeps
    what's freed (~2 GB held for nothing, then swapped; with Aide loading too, cappa ran out, 2026-11-07)."""
    import ctypes
    import gc
    gc.collect()
    ctypes.CDLL("libc.so.6").malloc_trim(0)


class Voice:
    def __init__(self):
        self.model = None
        self.conds: dict = {}
        self.lock = threading.Lock()  # one sentence at a time on the GPU

    # -- loading --

    def load(self) -> None:
        with self.lock:
            if self.model is not None:
                return
            from chatterbox.mtl_tts import ChatterboxMultilingualTTS
            started = time.monotonic()
            model = ChatterboxMultilingualTTS.from_pretrained(device="cuda")
            model.t3.half()  # as fast, less of the GPU
            self._spy(model)
            conds = {}
            for clip in sorted(VOICES.glob("*.wav")):
                model.prepare_conditionals(str(clip), exaggeration=0.5)
                conds[clip.stem] = model.conds
            for c in [model.conds, *conds.values()]:
                t = c.t3
                c.t3 = type(t)(speaker_emb=t.speaker_emb.half(), cond_prompt_speech_tokens=t.cond_prompt_speech_tokens,
                               emotion_adv=t.emotion_adv.half()).to(device="cuda")
            if not conds:
                log.warning("no voice clips in %s: the built-in voice speaks", VOICES)
            self.model, self.conds = model, conds
            for lang in ("it", "en"):  # the first sentence is slow
                for _ in self._stream("Ciao, come stai?" if lang == "it" else "Hello, how are you?", lang):
                    pass
            give_back()
            log.info("loaded in %.1f s, voices %s, %.2f GB (%.2f at most)", time.monotonic() - started, sorted(conds),
                     torch.cuda.memory_allocated() / 2**30, torch.cuda.max_memory_allocated() / 2**30)

    def _spy(self, model) -> None:
        """Chatterbox's alignment check (it stops a sentence that rambles on) reads three heads' attention: it hooked
        them again on every sentence, never letting go (3 more CPU copies a token each time), and put every layer on
        the slow eager attention. Here those three layers get eager attention of their own, hooked once; the rest
        keep SDPA."""
        import copy
        from chatterbox.models.t3.inference.alignment_stream_analyzer import LLAMA_ALIGNED_HEADS
        self.attns = [None] * len(LLAMA_ALIGNED_HEADS)
        for i, (layer, head) in enumerate(LLAMA_ALIGNED_HEADS):
            attn = model.t3.tfmr.layers[layer].self_attn
            attn.config = copy.copy(attn.config)
            attn.config._attn_implementation = "eager"

            def hook(module, args, output, i=i, head=head):
                if isinstance(output, tuple) and len(output) > 1 and output[1] is not None:
                    self.attns[i] = output[1][0, head].float().cpu()
            attn.register_forward_hook(hook)

    def release(self) -> None:
        with self.lock:
            self.model, self.conds = None, {}
        import gc
        gc.collect()
        torch.cuda.empty_cache()
        give_back()
        log.info("let go of the GPU")

    # -- speaking --

    def speak(self, text: str, lang: str):
        if self.model is None:
            self.load()
        with self.lock:
            if self.model is None:
                raise RuntimeError("not loaded")
            yield from self._stream(text, lang)

    @torch.inference_mode()
    def _tokens(self, conds, text: str, lang: str, most: int, cfg_weight=0.5, temperature=0.8,
                repetition_penalty=2.0, min_p=0.05, top_p=1.0):
        """Chatterbox's T3 sampling loop (mtl_tts.generate), a token at a time."""
        from chatterbox.models.t3.inference.t3_hf_backend import T3HuggingfaceBackend
        from chatterbox.mtl_tts import punc_norm
        from transformers.generation.logits_process import (MinPLogitsWarper, RepetitionPenaltyLogitsProcessor,
                                                            TopPLogitsWarper)
        m = self.model
        t3 = m.t3
        text_tokens = m.tokenizer.text_to_tokens(punc_norm(text), language_id=lang).to(m.device)
        text_tokens = torch.cat([text_tokens, text_tokens], dim=0)  # two rows for CFG
        text_tokens = F.pad(text_tokens, (1, 0), value=t3.hp.start_text_token)
        text_tokens = F.pad(text_tokens, (0, 1), value=t3.hp.stop_text_token)
        embeds, len_cond = t3.prepare_input_embeds(
            t3_cond=conds.t3, text_tokens=text_tokens,
            speech_tokens=t3.hp.start_speech_token * torch.ones_like(text_tokens[:, :1]), cfg_weight=cfg_weight)
        analyzer = _analyzer()(t3.tfmr, None, text_tokens_slice=(len_cond, len_cond + text_tokens.size(-1)),
                                 alignment_layer_idx=9, eos_idx=t3.hp.stop_speech_token)
        analyzer.last_aligned_attns = self.attns  # filled by the hooks of _spy
        backend = T3HuggingfaceBackend(config=t3.cfg, llama=t3.tfmr, speech_enc=t3.speech_emb,
                                       speech_head=t3.speech_head, alignment_stream_analyzer=analyzer)
        bos = torch.tensor([[t3.hp.start_speech_token]], dtype=torch.long, device=m.device)
        bos_embed = t3.speech_emb(bos) + t3.speech_pos_emb.get_fixed_embedding(0)
        # The prompt goes through with eager attention everywhere, so the hooked layers get its causal mask; a token at
        # a time needs none, and the rest of the layers go back to SDPA.
        t3.tfmr.config._attn_implementation = "eager"
        try:
            out = backend(inputs_embeds=torch.cat([embeds, torch.cat([bos_embed, bos_embed])], dim=1),
                          past_key_values=None, use_cache=True, output_hidden_states=True, return_dict=True)
        finally:
            t3.tfmr.config._attn_implementation = "sdpa"
        past, generated = out.past_key_values, bos.clone()
        top_p_w, min_p_w = TopPLogitsWarper(top_p=top_p), MinPLogitsWarper(min_p=min_p)
        repeat = RepetitionPenaltyLogitsProcessor(penalty=float(repetition_penalty))
        for i in range(most):
            step = out.logits[:, -1, :].float()
            logits = step[0:1] + cfg_weight * (step[0:1] - step[1:2])
            logits = analyzer.step(logits, next_token=generated[0, -1].item())
            logits = repeat(generated[:1], logits) / temperature
            logits = top_p_w(generated[:1], min_p_w(generated[:1], logits))
            token = torch.multinomial(torch.softmax(logits, dim=-1), num_samples=1)
            if token.view(-1) == t3.hp.stop_speech_token:
                return
            generated = torch.cat([generated, token], dim=1)
            yield token
            embed = t3.speech_emb(token) + t3.speech_pos_emb.get_fixed_embedding(i + 1)
            out = backend(inputs_embeds=torch.cat([embed, embed]), past_key_values=past, output_hidden_states=True,
                          return_dict=True)
            past = out.past_key_values

    @torch.inference_mode()
    def _stream(self, text: str, lang: str):
        """PCM16 bytes as they're made."""
        m = self.model
        conds = self.conds.get(lang) or m.conds
        g = m.s3gen
        toks: list[int] = []
        sent = 0  # tokens whose sound has gone out (bar the held fade)
        tail = None  # the last FADE samples made, kept for the crossfade at the next join

        def window(final: bool):
            nonlocal sent, tail
            upto = len(toks) if final else len(toks) - HOLD
            if upto <= sent:
                return None
            start = max(0, sent - CONTEXT)
            tokens = torch.tensor(toks[start:], dtype=torch.long, device=m.device)
            with torch.autocast("cuda", dtype=torch.float16):
                mels = g.flow_inference(tokens, ref_dict=conds.gen, finalize=True, n_cfm_timesteps=STEPS)
            if SPEED != 1:
                mels = F.interpolate(mels.float(), size=max(1, round(mels.shape[-1] / SPEED)), mode="linear")
            wav, _ = g.hift_inference(mels.to(dtype=g.dtype), None)
            wav = wav.squeeze(0).float()
            if start == 0:  # Chatterbox's fade-in against the clip spilling over
                n = min(len(g.trim_fade), wav.shape[-1])
                wav[:n] *= g.trim_fade[:n]
            per = wav.shape[-1] / len(tokens)  # samples a token (TOK at SPEED 1)
            begin = round((sent - start) * per)
            piece = wav[begin:] if final else wav[begin:round((upto - start) * per)]
            if tail is not None:  # the held end of the last window, faded into this window's take on it
                ramp = torch.linspace(0, 1, len(tail), device=wav.device)
                piece = torch.cat([tail * (1 - ramp) + wav[begin - len(tail):begin] * ramp, piece])
            if final:
                tail = None
            else:
                piece, tail = piece[:-FADE], piece[-FADE:]
            sent = upto
            return piece

        # The tokens are made in a thread of their own, so the model keeps going while a window is decoded.
        most = int(25 + 3.2 * len(text))  # ~1.8 tokens a character: a short line can't ramble on
        made: queue.Queue = queue.Queue()
        stop = threading.Event()

        def produce():
            try:
                with torch.inference_mode():
                    for token in self._tokens(conds, text, lang, most):
                        if stop.is_set():
                            break
                        made.put(int(token))
                made.put(None)
            except Exception as e:
                made.put(e)

        producer = threading.Thread(target=produce, daemon=True)
        producer.start()
        began, out = 0.0, 0.0  # when the first sound went, seconds of it sent since
        try:
            done = False
            while not done:
                got = [made.get()]
                while not made.empty():
                    got.append(made.get_nowait())
                for token in got:
                    if isinstance(token, Exception):
                        raise token
                    if token is None:
                        done = True
                    elif token < VALID:
                        toks.append(token)
                if done:
                    break
                new = len(toks) - HOLD - sent
                left = began + out - time.monotonic()
                if new >= (FIRST if not sent else SOON if left < LOW else EVERY):
                    if (piece := window(False)) is not None and len(piece):
                        began = began or time.monotonic()
                        out += len(piece) / 24000
                        yield _pcm(piece)
            if toks and (piece := window(True)) is not None and len(piece):
                yield _pcm(_trim_end(piece))
        finally:
            stop.set()
            producer.join()  # within a token; the next sentence mustn't share the model with it


def _analyzer():
    from chatterbox.models.t3.inference.alignment_stream_analyzer import AlignmentStreamAnalyzer

    class Analyzer(AlignmentStreamAnalyzer):
        def _add_attention_spy(self, *args):  # Voice._spy hooks them once
            pass

        def step(self, logits, next_token=None):
            """Upstream's, plus an end: TAIL tokens after the line's last words are reached, it's over. Upstream waits
            for the attention to pile up on them, but it wobbles over the last few, and a short line went on to the
            cap with made-up words or a long breath ("Checking the calendar. The calendar is on the Mon…", 2026-11-06)."""
            logits = super().step(logits, next_token)
            if self.completed_at is not None and self.alignment.shape[0] - self.completed_at >= TAIL:
                logits[..., self.eos_idx] = 2**15
            return logits
    return Analyzer


def _trim_end(wav: torch.Tensor) -> torch.Tensor:
    """Silence or a breath after the last word goes (keeps 120 ms)."""
    loud = (wav.abs() > 0.02).nonzero()
    if not len(loud):
        return wav
    return wav[: min(wav.shape[-1], int(loud[-1]) + 2880)]


def _pcm(wav: torch.Tensor) -> bytes:
    return (wav.clamp(-1, 1) * 32767).to(torch.int16).cpu().numpy().tobytes()


VOICE = Voice()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _reply(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self._reply(200, {"loaded": VOICE.model is not None, "voices": sorted(VOICE.conds)})
        self._reply(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        try:
            if self.path == "/load":
                VOICE.load()
                return self._reply(200, {"voices": sorted(VOICE.conds)})
            if self.path == "/release":
                VOICE.release()
                return self._reply(200, {})
            if self.path != "/speak":
                return self._reply(404, {"error": "not found"})
        except Exception as e:
            log.exception("%s failed", self.path)
            return self._reply(500, {"error": str(e)})
        text, lang = (body.get("text") or "").strip(), body.get("lang") or "en"
        if not text:
            return self._reply(400, {"error": "no text"})
        started = time.monotonic()
        self.send_response(200)
        self.send_header("Content-Type", "audio/L16; rate=24000; channels=1")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        first, total = None, 0
        try:
            for pcm in VOICE.speak(text, lang):
                first = first or time.monotonic() - started
                total += len(pcm)
                self.wfile.write(b"%x\r\n%s\r\n" % (len(pcm), pcm))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            log.info("%s %.2f s to the first sound, %.2f GB at most, %.1f s of audio in %.2f s: %s", lang, first or 0,
                     torch.cuda.max_memory_allocated() / 2**30, total / 2 / 24000, time.monotonic() - started, text[:60])
        except (BrokenPipeError, ConnectionResetError):
            log.info("%s stopped (talked over) after %.1f s of audio", lang, total / 2 / 24000)
        except Exception:
            log.exception("speaking failed: %s", text[:60])
            self.close_connection = True


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    for noisy in ("transformers", "diffusers", "chatterbox"):
        logging.getLogger(noisy).setLevel(logging.ERROR)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    log.info("listening on 127.0.0.1:%d, voices in %s", PORT, VOICES)
    server.serve_forever()


if __name__ == "__main__":
    main()
