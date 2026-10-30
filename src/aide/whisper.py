"""Transcription on the GPU (lectures, videos without captions), in a process of its own (study.py starts it), so
the models' memory is freed after each recording and the service never waits on it:

    python -m aide.whisper <audio file> [language]

English goes to NVIDIA's Parakeet, which made fewer mistakes than Whisper on English talks and runs about 7 times
faster (tried 2026-10-30: 22 minutes in 4 s); anything else to faster-whisper, which also picks the language when
it isn't given. When Parakeet can't run, English goes to Whisper too.

Prints one JSON line per segment, [start in seconds, text], then {"language": ..., "duration": ..., "model": ...}.
Needs the `whisper` extra (uv sync --extra whisper), which only the server box installs.
"""

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

MODEL = "large-v3-turbo"  # about 1.6 GB, downloaded to ~/.cache/huggingface on first use
PARAKEET = "nvidia/parakeet-tdt-0.6b-v2"  # English only, about 2.4 GB, downloaded there too


def available() -> bool:
    return importlib.util.find_spec("faster_whisper") is not None


def cuda_libs() -> str:
    """The lib folders of the nvidia pip wheels (cuBLAS, cuDNN), for LD_LIBRARY_PATH; "" without them."""
    try:
        import nvidia
    except ImportError:
        return ""
    return os.pathsep.join(str(p) for base in nvidia.__path__ for p in sorted(Path(base).glob("*/lib")))


def decode(path: str):
    """16 kHz mono samples, decoded by ffmpeg (faster-whisper's own decoder breaks on newer PyAV releases)."""
    import numpy as np

    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-f", "s16le", "-ac", "1", "-ar", "16000", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.int16).astype(np.float32) / 32768


def parakeet(audio) -> list[tuple[float, str]]:
    """English through Parakeet, the whole recording at once (its local attention keeps a 90-minute lecture in the
    card's memory), as (start, text) a sentence each."""
    import logging

    import torch
    from nemo.collections.asr.models import ASRModel
    from nemo.utils import logging as nemo_log

    nemo_log.setLevel(logging.ERROR)
    model = ASRModel.from_pretrained(PARAKEET).cuda().eval()
    model.change_attention_model("rel_pos_local_attn", [256, 256])
    model.change_subsampling_conv_chunking_factor(1)
    with torch.autocast("cuda", dtype=torch.float16), torch.inference_mode():
        out = model.transcribe([audio], batch_size=1, timestamps=True, verbose=False)[0]
    return [(s["start"], s["segment"].strip()) for s in out.timestamp["segment"]]


def main() -> None:
    from faster_whisper import WhisperModel

    path, language = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
    audio = decode(path)
    model = WhisperModel(os.environ.get("AIDE_WHISPER_MODEL") or MODEL, device="cuda", compute_type="int8_float16")
    if language is None:
        # A few stretches of speech, not just the first 30 s: a lecture can open with chatter in another language.
        language, _, _ = model.detect_language(audio, vad_filter=True, language_detection_segments=4)
    if language == "en":
        del model  # the card's memory for Parakeet
        try:
            for start, text in parakeet(audio):
                if text:
                    print(json.dumps([round(start, 1), text], ensure_ascii=False), flush=True)
            print(json.dumps({"language": "en", "duration": round(len(audio) / 16000), "model": "parakeet"}),
                  flush=True)
            return
        except Exception as e:  # not installed, the download failed, out of memory: Whisper does it
            print(f"parakeet failed, using whisper: {e!r}", file=sys.stderr, flush=True)
            model = WhisperModel(os.environ.get("AIDE_WHISPER_MODEL") or MODEL, device="cuda",
                                 compute_type="int8_float16")
    # Not conditioned on the text before: on long recordings that's what makes Whisper repeat itself in a loop.
    segments, info = model.transcribe(audio, language=language, vad_filter=True, condition_on_previous_text=False)
    for s in segments:
        if text := s.text.strip():
            print(json.dumps([round(s.start, 1), text], ensure_ascii=False), flush=True)
    print(json.dumps({"language": info.language, "duration": round(info.duration), "model": "whisper"}), flush=True)


if __name__ == "__main__":
    main()
