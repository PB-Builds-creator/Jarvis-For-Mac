from __future__ import annotations

import contextlib
import io
import json
import os
import re
import subprocess
import time
import wave
from functools import lru_cache
from pathlib import Path
from typing import Any

from .config import (
    DATA_DIR,
    JARVIS_TTS_PRIMARY_MODEL_DIR,
    JARVIS_TTS_PRIMARY_MODEL_PATH,
    JARVIS_TTS_PRIMARY_TOKENIZER_PATH,
    JARVIS_TTS_REFERENCE_PATH,
    JARVIS_TTS_PRESET_MODEL_DIR,
    JARVIS_TTS_PRESET_MODEL_PATH,
    JARVIS_TTS_MODEL_DIR,
    JARVIS_TTS_MODEL_PATH,
    JARVIS_TTS_VOICE_PATH,
    PRIVATE_FILE_MODE,
    ensure_dirs,
    load_config,
)


SAMPLE_RATE = 24_000
MODEL_LICENSE = "Apache-2.0"
MODEL_REVISION = "a71e4d38b236d968966a2002c4c895dbd12b1c3c"
VOICE_NAME = "bm_george"
PRIMARY_MODEL_REVISION = "50f45ef0047cde7e84c2ef04326acb8ada2436a7"
DESIGN_MODEL_REVISION = "6e936cfb98d95b707bd1f85351874a377230fe83"
PRESET_MODEL_REVISION = "f35faf19b0cc2160865af64ecf0f22f83d335135"
PRIMARY_VOICE_NAME = "Jarvis Cinematic English"
PRESET_VOICE_NAME = "Ryan"
PRIMARY_REFERENCE_TEXT = (
    "Good evening. The laboratory and armour systems are ready. After "
    "reviewing the data, I rather think we should wait. Everything remains under "
    "control, sir."
)
PRIMARY_VOICE_INSTRUCTION = (
    "An entirely original cinematic artificial-intelligence voice: an English man in "
    "his early forties with unmistakably native modern Received Pronunciation, clipped "
    "British consonants, non-rhotic final R sounds, and broad Southern English vowels. "
    "Use a smooth low-mid baritone, polished dulcet tone, precise diction, controlled "
    "deadpan delivery, restrained warmth, quiet competence, and the faintest dry wit. "
    "Keep emotion subtle and let sentence endings settle downward. Never sound elderly, "
    "theatrical, breathy, gravelly, or American. Do not imitate any real person or "
    "existing character."
)
_TOKEN_RE = re.compile(r"[A-Za-z]+(?:['’-][A-Za-z]+)*|\d+|[.,!?;:()—–-]")
_LETTER_IPA = {
    "a": "ˈeɪ", "b": "bˈiː", "c": "sˈiː", "d": "dˈiː", "e": "ˈiː",
    "f": "ˈɛf", "g": "dʒˈiː", "h": "ˈeɪtʃ", "i": "ˈaɪ", "j": "dʒˈeɪ",
    "k": "kˈeɪ", "l": "ˈɛl", "m": "ˈɛm", "n": "ˈɛn", "o": "ˈəʊ",
    "p": "pˈiː", "q": "kjˈuː", "r": "ˈɑː", "s": "ˈɛs", "t": "tˈiː",
    "u": "jˈuː", "v": "vˈiː", "w": "dˈʌbəljˌuː", "x": "ˈɛks",
    "y": "wˈaɪ", "z": "zˈɛd",
}
_OVERRIDES = {
    "jarvis": "dʒˈɑːvɪs",
    "chatgpt": "tʃˈæt dʒˌiː pˌiː tˌiː",
    "tradingview": "tɹˈeɪdɪŋ vjˌuː",
    "mgc": "ˌɛm dʒˌiː sˈiː",
    "dxy": "dˌiː ˌɛks wˈaɪ",
    "vwap": "vˈiː wˌɒp",
    "fvg": "ˌɛf vˌiː dʒˈiː",
    "fibonacci": "fˌɪbənˈɑːtʃi",
    "discord": "dˈɪskɔːd",
    "macos": "mˈæk ˌəʊ ˈɛs",
    "siri": "sˈɪɹi",
}
_SMALL_NUMBERS = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
    "sixteen", "seventeen", "eighteen", "nineteen",
]
_TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]


def _integer_words(value: int) -> str:
    if value < 0:
        return "minus " + _integer_words(-value)
    if value < 20:
        return _SMALL_NUMBERS[value]
    if value < 100:
        return _TENS[value // 10] + (("-" + _SMALL_NUMBERS[value % 10]) if value % 10 else "")
    if value < 1_000:
        return _SMALL_NUMBERS[value // 100] + " hundred" + (
            (" and " + _integer_words(value % 100)) if value % 100 else ""
        )
    if value < 1_000_000:
        return _integer_words(value // 1_000) + " thousand" + (
            (" " + _integer_words(value % 1_000)) if value % 1_000 else ""
        )
    return " ".join(_SMALL_NUMBERS[int(digit)] for digit in str(value))


@lru_cache(maxsize=1)
def _lexicon() -> dict[str, str]:
    import misaki

    root = Path(misaki.__file__).parent / "data"
    values: dict[str, str] = {}
    for name in ("gb_silver.json", "gb_gold.json"):
        values.update(json.loads((root / name).read_text(encoding="utf-8")))
    return values


def _lookup_word(word: str, lexicon: dict[str, str]) -> str:
    def pronunciation(value: object) -> str:
        if isinstance(value, str):
            return value
        if isinstance(value, dict):
            selected = value.get("DEFAULT")
            if isinstance(selected, str):
                return selected
            return next((item for item in value.values() if isinstance(item, str)), "")
        return ""

    lower = word.casefold().replace("’", "'")
    if lower in _OVERRIDES:
        return _OVERRIDES[lower]
    for candidate in (word, lower, lower.capitalize()):
        if candidate in lexicon:
            return pronunciation(lexicon[candidate])
    # The compact dictionary contains roots but not every inflection.
    for suffix, sound in (
        ("ies", "iz"), ("es", "ɪz"), ("s", "z"), ("ed", "d"), ("ing", "ɪŋ")
    ):
        if lower.endswith(suffix) and len(lower) > len(suffix) + 2:
            roots = [lower[: -len(suffix)]]
            if suffix == "ies":
                roots.append(lower[:-3] + "y")
            if suffix in {"ed", "ing"}:
                roots.append(lower[: -len(suffix)] + "e")
            for root in roots:
                if root in lexicon:
                    return pronunciation(lexicon[root]) + sound
    # Acronyms and rare proper nouns remain intelligible without a second
    # phonemization model: pronounce their letters using British names.
    return " ".join(_LETTER_IPA[letter] for letter in lower if letter in _LETTER_IPA)


def phonemize_british(text: str) -> str:
    lexicon = _lexicon()
    expanded = re.sub(
        r"\b\d+\b",
        lambda match: _integer_words(int(match.group(0))),
        text,
    )
    parts: list[str] = []
    for token in _TOKEN_RE.findall(expanded):
        if token[0].isalpha():
            parts.append(_lookup_word(token, lexicon))
        elif token in {".", "!", "?"}:
            parts.append(token)
        elif token in {",", ";", ":"}:
            parts.append(",")
        elif token in {"—", "–", "-"}:
            parts.append(",")
    return " ".join(parts).strip()


def _phoneme_chunks(phonemes: str, limit: int = 480) -> list[str]:
    if len(phonemes) <= limit:
        return [phonemes]
    chunks: list[str] = []
    remaining = phonemes
    while remaining:
        if len(remaining) <= limit:
            chunks.append(remaining)
            break
        cut = max(
            remaining.rfind(marker, 0, limit)
            for marker in (".", "?", "!", ",", " ")
        )
        if cut < limit // 2:
            cut = limit
        chunks.append(remaining[: cut + 1].strip())
        remaining = remaining[cut + 1 :].strip()
    return [chunk for chunk in chunks if chunk]


def _text_chunks(text: str, limit: int = 260) -> list[str]:
    """Split long replies at natural boundaries for stable, prompt playback."""
    if len(text) <= limit:
        return [text]
    sentences = re.split(r"(?<=[.!?])\s+", text)
    chunks: list[str] = []
    current = ""
    for sentence in sentences:
        remaining = sentence.strip()
        while len(remaining) > limit:
            cut = remaining.rfind(" ", 0, limit + 1)
            if cut < limit // 2:
                cut = limit
            piece = remaining[:cut].strip()
            if current:
                chunks.append(current)
                current = ""
            if piece:
                chunks.append(piece)
            remaining = remaining[cut:].strip()
        candidate = f"{current} {remaining}".strip()
        if current and len(candidate) > limit:
            chunks.append(current)
            current = remaining
        else:
            current = candidate
    if current:
        chunks.append(current)
    return [chunk for chunk in chunks if chunk]


def _cinematic_voice_mix(audio: Any) -> Any:
    """Add a restrained in-world AI texture without sacrificing intelligibility."""
    import numpy as np
    from scipy.signal import butter, sosfilt

    dry = np.asarray(audio, dtype=np.float32).reshape(-1)
    if dry.size < 2:
        return dry
    # Remove sub-bass and extreme top end, then add two nearly inaudible short
    # reflections. This produces the tight doubled texture of a voice heard
    # through an advanced interface without turning it into a robot effect.
    band = butter(2, (72.0, 11_200.0), btype="bandpass", fs=SAMPLE_RATE, output="sos")
    shaped = sosfilt(band, dry).astype(np.float32)
    mixed = shaped.copy()
    for delay_ms, gain in ((8.5, 0.035), (17.0, -0.018), (31.0, 0.012)):
        offset = max(1, round(SAMPLE_RATE * delay_ms / 1000.0))
        if offset < mixed.size:
            mixed[offset:] += gain * shaped[:-offset]
    # Very gentle soft limiting keeps replies consistent across speakers while
    # leaving the natural dynamics and consonants intact.
    mixed = np.tanh(mixed * 1.06) / np.tanh(1.06)
    peak = float(np.max(np.abs(mixed)))
    if peak > 0.94:
        mixed *= 0.94 / peak
    return mixed.astype(np.float32)


def speech_status() -> dict[str, Any]:
    cfg = load_config()
    primary_ready = (
        JARVIS_TTS_PRIMARY_MODEL_PATH.is_file()
        and JARVIS_TTS_PRIMARY_TOKENIZER_PATH.is_file()
        and JARVIS_TTS_REFERENCE_PATH.is_file()
    )
    preset_ready = JARVIS_TTS_PRESET_MODEL_PATH.is_file()
    lightweight_ready = (
        JARVIS_TTS_MODEL_PATH.is_file() and JARVIS_TTS_VOICE_PATH.is_file()
    )
    return {
        "enabled": cfg.neural_voice_enabled,
        "ready": primary_ready or preset_ready or lightweight_ready,
        "engine": (
            "Qwen3-TTS cinematic British voice via MLX Audio"
            if primary_ready
            else "Qwen3-TTS 1.7B CustomVoice 4-bit via MLX Audio"
            if preset_ready
            else "Kokoro-82M via MLX Audio"
        ),
        "voice": (
            PRIMARY_VOICE_NAME
            if primary_ready else PRESET_VOICE_NAME if preset_ready else VOICE_NAME
        ),
        "style": "cinematic, clipped British AI voice with restrained dry wit",
        "licensed_voice_clone": False,
        "model_license": MODEL_LICENSE,
        "model_revision": (
            PRIMARY_MODEL_REVISION
            if primary_ready else PRESET_MODEL_REVISION if preset_ready else MODEL_REVISION
        ),
        "primary_ready": primary_ready,
        "designed_reference_ready": JARVIS_TTS_REFERENCE_PATH.is_file(),
        "preset_fallback_ready": preset_ready,
        "lightweight_fallback_ready": lightweight_ready,
        "loads_on_demand": True,
        "resident_ram_while_idle_mb": 0,
        "thermal_guard": "Falls back to the Apple voice during macOS thermal pressure",
        "fallback": "Apple British system voice",
    }


def _synthesize_qwen(clean: str) -> tuple[bytes, str]:
    import mlx.core as mx
    import numpy as np
    from mlx_audio.tts.utils import load_model

    model = load_model(JARVIS_TTS_PRIMARY_MODEL_DIR, lazy=False)
    mx.random.seed(20260805)
    audio_parts: list[Any] = []
    chunks = _text_chunks(clean)
    for index, chunk in enumerate(chunks):
        generated = model.generate(
            chunk,
            ref_audio=str(JARVIS_TTS_REFERENCE_PATH),
            ref_text=PRIMARY_REFERENCE_TEXT,
            lang_code="english",
            temperature=0.72,
            top_k=35,
            top_p=0.90,
            repetition_penalty=1.08,
            max_tokens=4096,
            verbose=False,
        )
        for result in generated:
            audio_parts.append(np.asarray(result.audio).reshape(-1))
        if index < len(chunks) - 1:
            audio_parts.append(np.zeros(int(SAMPLE_RATE * 0.11), dtype=np.float32))
    if not audio_parts:
        raise RuntimeError("The primary neural voice generated no audio.")
    audio = _cinematic_voice_mix(np.concatenate(audio_parts))
    audio = np.clip(audio, -1.0, 1.0)
    pcm = (audio * 32767.0).astype("<i2").tobytes()
    mx.clear_cache()
    return pcm, "Qwen3-TTS cinematic British voice via MLX Audio"


def _synthesize_qwen_preset(clean: str) -> tuple[bytes, str]:
    import mlx.core as mx
    import numpy as np
    from mlx_audio.tts.utils import load_model

    model = load_model(JARVIS_TTS_PRESET_MODEL_DIR, lazy=False)
    audio_parts: list[Any] = []
    chunks = _text_chunks(clean)
    for index, chunk in enumerate(chunks):
        for result in model.generate(
            chunk,
            voice=PRESET_VOICE_NAME,
            instruct=PRIMARY_VOICE_INSTRUCTION,
            lang_code="english",
            temperature=0.72,
            top_k=35,
            top_p=0.90,
            repetition_penalty=1.08,
            max_tokens=4096,
            verbose=False,
        ):
            audio_parts.append(np.asarray(result.audio).reshape(-1))
        if index < len(chunks) - 1:
            audio_parts.append(np.zeros(int(SAMPLE_RATE * 0.11), dtype=np.float32))
    if not audio_parts:
        raise RuntimeError("The preset neural voice generated no audio.")
    audio = np.clip(np.concatenate(audio_parts), -1.0, 1.0)
    pcm = (audio * 32767.0).astype("<i2").tobytes()
    mx.clear_cache()
    return pcm, "Qwen3-TTS 1.7B CustomVoice 4-bit via MLX Audio"


def _synthesize_kokoro(clean: str, speed: float) -> tuple[bytes, str]:
    import mlx.core as mx
    import numpy as np
    from mlx_audio.tts.models.kokoro import KokoroPipeline
    from mlx_audio.tts.utils import load_model

    phonemes = phonemize_british(clean)
    chunks = _phoneme_chunks(phonemes)
    model = load_model(JARVIS_TTS_MODEL_DIR, lazy=False)
    pipeline = KokoroPipeline.__new__(KokoroPipeline)
    pipeline.model = model
    pipeline.repo_id = str(JARVIS_TTS_MODEL_DIR)
    pipeline.voices = {}
    audio_parts: list[Any] = []
    for chunk in chunks:
        for result in pipeline.generate_from_tokens(
            chunk,
            voice=str(JARVIS_TTS_VOICE_PATH),
            speed=speed,
            model=model,
        ):
            audio_parts.append(np.asarray(result.audio).reshape(-1))
    if not audio_parts:
        raise RuntimeError("The lightweight neural voice generated no audio.")
    audio = np.clip(np.concatenate(audio_parts), -1.0, 1.0)
    pcm = (audio * 32767.0).astype("<i2").tobytes()
    mx.clear_cache()
    return pcm, "Kokoro-82M via MLX Audio"


def _thermal_pressure_active() -> bool:
    try:
        result = subprocess.run(
            ["/usr/bin/pmset", "-g", "therm"],
            text=True,
            capture_output=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    output = (result.stdout + "\n" + result.stderr).casefold()
    if "no thermal warning level has been recorded" in output:
        return False
    return any(
        marker in output
        for marker in (
            "thermal warning",
            "thermal level",
            "cpu_speed_limit",
            "scheduler limit",
        )
    )


def _cleanup_old_audio(directory: Path, maximum_age_seconds: int = 600) -> None:
    cutoff = time.time() - maximum_age_seconds
    for path in directory.glob("jarvis-speech-*.wav"):
        try:
            if path.stat().st_mtime < cutoff:
                path.unlink()
        except OSError:
            pass


def synthesize_speech(text: str) -> dict[str, Any]:
    cfg = load_config()
    clean = re.sub(r"\s+", " ", text).strip()[: cfg.neural_voice_max_chars]
    if not clean:
        raise ValueError("Speech text cannot be empty.")
    status = speech_status()
    if not cfg.neural_voice_enabled or not status["ready"]:
        raise RuntimeError("The local Jarvis neural voice is not installed.")
    if _thermal_pressure_active():
        raise RuntimeError(
            "macOS reports thermal pressure; use the lightweight Apple voice fallback."
        )

    ensure_dirs()
    output_dir = DATA_DIR / "runtime" / "tts"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_dir.chmod(0o700)
    _cleanup_old_audio(output_dir)
    output_path = output_dir / f"jarvis-speech-{os.getpid()}-{time.time_ns()}.wav"
    # MLX Audio prints model details during import/load. Keep stdout machine
    # readable for the native app and let this short-lived process release all
    # model memory immediately after synthesis.
    muted = io.StringIO()
    with contextlib.redirect_stdout(muted), contextlib.redirect_stderr(muted):
        if status["primary_ready"]:
            try:
                pcm, engine = _synthesize_qwen(clean)
            except Exception:
                if status["preset_fallback_ready"]:
                    pcm, engine = _synthesize_qwen_preset(clean)
                elif status["lightweight_fallback_ready"]:
                    pcm, engine = _synthesize_kokoro(clean, cfg.neural_voice_speed)
                else:
                    raise
        else:
            if status["preset_fallback_ready"]:
                pcm, engine = _synthesize_qwen_preset(clean)
            else:
                pcm, engine = _synthesize_kokoro(clean, cfg.neural_voice_speed)

    with wave.open(str(output_path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(pcm)
    output_path.chmod(PRIVATE_FILE_MODE)
    return {
        "path": str(output_path),
        "sample_rate": SAMPLE_RATE,
        "duration_seconds": round(len(pcm) / 2 / SAMPLE_RATE, 3),
        "engine": engine,
        "voice": (
            PRIMARY_VOICE_NAME
            if engine.startswith("Qwen3-TTS cinematic")
            else PRESET_VOICE_NAME
            if engine.startswith("Qwen3")
            else VOICE_NAME
        ),
    }
