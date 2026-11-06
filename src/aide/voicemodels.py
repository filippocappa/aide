"""The models behind a live call's local voice (localvoice.Backend), in the service's own process on cappa's GPU.

Silero (speech or not, ONNX on the CPU), smart-turn v3.2 (finished or not, ONNX on the CPU), Parakeet v3 (the
words, GPU) and Kokoro (the voice, GPU). Loading them all takes ~25 s, so they're loaded when the service starts and
kept (~5 GB of the 2080's 8). A lecture or a video for Whisper borrows the GPU: it waits for any call to end, the GPU
models are let go, and they're loaded again after (`lend_gpu`); a call asked for meanwhile doesn't start, and the
phone uses its turn-at-a-time voice."""

import asyncio
import contextlib
import logging
import threading
import time
from typing import AsyncIterator, Callable

log = logging.getLogger(__name__)

RATE = 24000
TURN_MODEL = ("pipecat-ai/smart-turn-v3", "smart-turn-v3.2-cpu.onnx")
ASR_MODEL = "nvidia/parakeet-tdt-0.6b-v3"
TURN_SECONDS = 8  # what the turn model hears: the utterance's end
LANGS = {"en": "a", "it": "i"}

_shared: "VoiceModels | None" = None


def _floats16k(pcm: bytes):
    """PCM16 at 24 kHz as float samples at 16 kHz."""
    import numpy as np
    from scipy.signal import resample_poly

    return resample_poly(np.frombuffer(pcm, np.int16).astype(np.float32) / 32768, 2, 3).astype(np.float32)


class VoiceModels:
    turns = True

    def __init__(self, voices: dict[str, str] | None = None, speed: float = 1.0):
        self.voices = voices or {"en": "af_heart", "it": "if_sara"}
        self.speed = speed
        self.calls = 0
        self.lent = 0
        self._asr = self._pipes = None
        self._turn = self._features = None
        self._loading = asyncio.Lock()
        self._gpu = threading.Lock()  # one GPU job at a time
        self._warming: asyncio.Task | None = None

    # -- loading --

    @property
    def ready(self) -> bool:
        return self._asr is not None and self._pipes is not None

    async def warm(self) -> None:
        """Loads what isn't loaded; RuntimeError while a job has the GPU."""
        if self.lent:
            raise RuntimeError("the GPU is transcribing a recording; try again in a few minutes")
        async with self._loading:
            if not self.ready:
                started = time.monotonic()
                await asyncio.to_thread(self._load)
                log.info("live call voice loaded in %.1f s", time.monotonic() - started)

    def _load(self) -> None:
        import logging as stdlog

        import onnxruntime as ort
        import torch
        from huggingface_hub import hf_hub_download
        from transformers import WhisperFeatureExtractor

        if self._turn is None:
            options = ort.SessionOptions()
            options.inter_op_num_threads = 1
            options.intra_op_num_threads = 2
            self._turn = ort.InferenceSession(hf_hub_download(*TURN_MODEL), sess_options=options,
                                              providers=["CPUExecutionProvider"])
            self._features = WhisperFeatureExtractor(chunk_length=TURN_SECONDS)
        from nemo.collections.asr.models import ASRModel
        from nemo.utils import logging as nemo_log
        nemo_log.setLevel(stdlog.ERROR)
        asr = ASRModel.from_pretrained(ASR_MODEL).cuda().eval()
        from kokoro import KModel, KPipeline
        kokoro = KModel().to("cuda").eval()
        pipes = {lang: KPipeline(lang_code=code, model=kokoro) for lang, code in LANGS.items()}
        for lang, pipe in pipes.items():  # the first sentence is slow; get it over with
            for _ in pipe("Ciao." if lang == "it" else "Hello.", voice=self.voices[lang], speed=self.speed):
                pass
        with torch.inference_mode():
            asr.transcribe([_floats16k(b"\0" * RATE)], batch_size=1, verbose=False)
        self._asr, self._pipes = asr, pipes

    def release(self) -> None:
        """Lets the GPU models go (the CPU ones stay)."""
        with self._gpu:
            self._asr = self._pipes = None
        import gc

        import torch
        gc.collect()
        torch.cuda.empty_cache()

    @contextlib.asynccontextmanager
    async def lend(self):
        self.lent += 1
        try:
            while self.calls:
                await asyncio.sleep(2)
            if self.ready:
                async with self._loading:
                    await asyncio.to_thread(self.release)
                log.info("live call voice let go for a transcription")
            yield
        finally:
            self.lent -= 1
            if not self.lent:
                self._warming = asyncio.create_task(self._warm_quietly())

    async def _warm_quietly(self) -> None:
        try:
            await self.warm()
        except Exception:
            log.exception("live call voice: loading failed")

    # -- localvoice.Backend --

    def opened(self) -> None:
        self.calls += 1

    def closed(self) -> None:
        self.calls -= 1

    def vad(self) -> Callable[[bytes], float]:
        import numpy as np
        from pysilero_vad import SileroVoiceActivityDetector

        detector = SileroVoiceActivityDetector()

        def chance(frame: bytes) -> float:
            samples = np.clip(_floats16k(frame) * 32768, -32768, 32767).astype(np.int16)
            return float(detector(samples.tobytes()))
        return chance

    async def finished(self, pcm: bytes) -> float:
        def run() -> float:
            import numpy as np

            audio = _floats16k(pcm)[-TURN_SECONDS * 16000:]
            inputs = self._features(audio, sampling_rate=16000, return_tensors="np", padding="max_length",
                                    max_length=TURN_SECONDS * 16000, truncation=True, do_normalize=True)
            features = np.expand_dims(inputs.input_features.squeeze(0).astype(np.float32), 0)
            return float(self._turn.run(None, {"input_features": features})[0][0].item())
        return await asyncio.to_thread(run)

    async def transcribe(self, pcm: bytes) -> str:
        def run() -> str:
            import torch

            with self._gpu:
                if self._asr is None:
                    raise RuntimeError("the voice's models aren't loaded")
                with torch.autocast("cuda", dtype=torch.float16), torch.inference_mode():
                    out = self._asr.transcribe([_floats16k(pcm)], batch_size=1, verbose=False)[0]
            return out.text if hasattr(out, "text") else str(out)
        return await asyncio.to_thread(run)

    async def speak(self, text: str, language: str) -> AsyncIterator[bytes]:
        lang = language if language in LANGS else "en"

        def run() -> list[bytes]:
            import numpy as np

            with self._gpu:
                if self._pipes is None:
                    raise RuntimeError("the voice's models aren't loaded")
                out = []
                for result in self._pipes[lang](text, voice=self.voices[lang], speed=self.speed):
                    if result.audio is not None:
                        audio = result.audio.detach().cpu().numpy()
                        out.append((np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes())
                return out
        for pcm in await asyncio.to_thread(run):
            yield pcm


def available() -> bool:
    """Whether the local voice's packages are installed (the `whisper` extra) and there's a GPU."""
    try:
        import importlib.util
        if not all(importlib.util.find_spec(m) for m in ("kokoro", "nemo", "pysilero_vad", "onnxruntime")):
            return False
        import torch
        return torch.cuda.is_available()
    except Exception:
        return False


def shared(voices: dict[str, str] | None = None, speed: float = 1.0) -> VoiceModels:
    """The service's one set of models."""
    global _shared
    if _shared is None:
        _shared = VoiceModels(voices, speed)
    return _shared


@contextlib.asynccontextmanager
async def lend_gpu():
    """Around a GPU job in another process (Whisper): the voice's models step aside while it runs."""
    if _shared is None:
        yield
        return
    async with _shared.lend():
        yield
