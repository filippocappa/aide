"""Lecture transcription with faster-whisper on the GPU, in a process of its own (study.py starts it), so the
model's memory is freed after each lecture and the service never waits on it:

    python -m aide.whisper <audio file> [language]

Prints one JSON line per segment, [start in seconds, text], then {"language": ..., "duration": ...}.
Needs the `whisper` extra (uv sync --extra whisper), which only the server box installs.
"""

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

MODEL = "large-v3-turbo"  # about 1.6 GB, downloaded to ~/.cache/huggingface on first use


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


def main() -> None:
    from faster_whisper import WhisperModel

    path, language = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
    model = WhisperModel(os.environ.get("AIDE_WHISPER_MODEL") or MODEL, device="cuda", compute_type="int8_float16")
    # Not conditioned on the text before: on long recordings that's what makes Whisper repeat itself in a loop.
    segments, info = model.transcribe(decode(path), language=language, vad_filter=True,
                                      condition_on_previous_text=False)
    for s in segments:
        if text := s.text.strip():
            print(json.dumps([round(s.start, 1), text], ensure_ascii=False), flush=True)
    print(json.dumps({"language": info.language, "duration": round(info.duration)}), flush=True)


if __name__ == "__main__":
    main()
