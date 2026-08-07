from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, asdict
from pathlib import Path


HOME = Path.home()
JARVIS_ROOT = Path(os.environ.get("JARVIS_ROOT", str(HOME / "Jarvis"))).expanduser()
DATA_DIR = Path(os.environ.get("JARVIS_DATA_DIR", str(JARVIS_ROOT / "Data"))).expanduser()
DB_PATH = DATA_DIR / "jarvis.db"
INFORMATION_DIR = JARVIS_ROOT / "Information"
SCREENSHOT_DIR = INFORMATION_DIR / "Screenshots"
TRADING_CHART_DIR = INFORMATION_DIR / "Trading" / "Chart Reviews"
EXPORT_DIR = INFORMATION_DIR / "Memory Exports"
INBOX_DIR = INFORMATION_DIR / "Inbox"
CONFIG_PATH = DATA_DIR / "no_api_config.json"
DESKTOP_THREADS_PATH = DATA_DIR / "desktop_threads.json"
NATIVE_HELPER = DATA_DIR / "bin" / "jarvis-native"
FOUNDATION_PLANNER_HELPER = DATA_DIR / "bin" / "jarvis-foundation-planner"
PERSONAL_DATA_HELPER = DATA_DIR / "bin" / "jarvis-personal-data"
KEYCHAIN_HELPER = DATA_DIR / "bin" / "jarvis-keychain"
VOICEPRINT_HELPER = DATA_DIR / "bin" / "jarvis-voiceprint"
JARVIS_APP_BINARY = JARVIS_ROOT / "App" / "Jarvis.app" / "Contents" / "MacOS" / "Jarvis"
MODELS_DIR = JARVIS_ROOT / "Models"
OWNER_VOICE_MODEL_PATH = MODELS_DIR / "OwnerVoice" / "wespeaker_v2.mlmodelc"
JARVIS_TTS_MODEL_DIR = MODELS_DIR / "JarvisVoice" / "Kokoro-82M-bf16"
JARVIS_TTS_MODEL_PATH = JARVIS_TTS_MODEL_DIR / "kokoro-v1_0.safetensors"
JARVIS_TTS_VOICE_PATH = JARVIS_TTS_MODEL_DIR / "voices" / "bm_george.safetensors"
JARVIS_TTS_PRIMARY_MODEL_DIR = (
    MODELS_DIR / "JarvisVoice" / "Qwen3-TTS-12Hz-0.6B-Base-8bit"
)
JARVIS_TTS_PRIMARY_MODEL_PATH = JARVIS_TTS_PRIMARY_MODEL_DIR / "model.safetensors"
JARVIS_TTS_PRIMARY_TOKENIZER_PATH = (
    JARVIS_TTS_PRIMARY_MODEL_DIR / "speech_tokenizer" / "model.safetensors"
)
JARVIS_TTS_REFERENCE_PATH = (
    MODELS_DIR / "JarvisVoice" / "OwnerProfile" / "reference.wav"
)
JARVIS_TTS_PRESET_MODEL_DIR = (
    MODELS_DIR / "JarvisVoice" / "Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit"
)
JARVIS_TTS_PRESET_MODEL_PATH = JARVIS_TTS_PRESET_MODEL_DIR / "model.safetensors"
LOCAL_AI_MODEL_DIR = MODELS_DIR / "Qwen3.5-4B-OptiQ-4bit"
LOCAL_AI_LARGE_MODEL_DIR = MODELS_DIR / "Qwen3.5-9B-4bit"
WHISPER_MODEL_PATH = MODELS_DIR / "Whisper" / "ggml-large-v3-turbo-q5_0.bin"
DEFAULT_TRANSCRIPTION_FALLBACK_COMMAND = (
    f"/opt/homebrew/bin/whisper-cli -m {WHISPER_MODEL_PATH} "
    "-l en -t 4 -nt -np --prompt "
    "'Jarvis, Siri, TradingView, MGC, DXY, VWAP, New York range, "
    "fair value gap, Fibonacci, ChatGPT' -f {audio}"
)
DEFAULT_VISUAL_FALLBACK_COMMAND = (
    f"{JARVIS_ROOT}/Code/.venv/bin/mlx_vlm.generate "
    f"--model {LOCAL_AI_MODEL_DIR} --image {{image}} --prompt '{{prompt}}' "
    "--max-tokens 192 --temperature 0 --max-kv-size 1024 --no-verbose"
)
PRIVATE_DIRECTORY_MODE = 0o700
PRIVATE_FILE_MODE = 0o600


def safe_owner_name(value: object) -> str:
    """Return a short display name that cannot add structure to model prompts."""
    cleaned = re.sub(r"[^\w .'-]+", "", str(value or "").strip(), flags=re.UNICODE)
    cleaned = re.sub(r"\s+", " ", cleaned)[:60].strip()
    return cleaned or "the owner"


@dataclass
class JarvisConfig:
    owner_name: str = os.environ.get("JARVIS_OWNER_NAME", "Owner")
    approved_chrome_profile_email: str = os.environ.get(
        "JARVIS_CHROME_PROFILE_EMAIL", ""
    )
    project_url: str = "https://chatgpt.com/"
    desktop_app_path: str = "/Applications/ChatGPT.app"
    chat_workspace: str = str(DATA_DIR)
    work_workspace: str = str(JARVIS_ROOT / "Code")
    default_mode: str = "confirm"
    allow_typing_without_prompt: bool = False
    allow_file_delete: bool = False
    allow_financial_actions: bool = False
    max_context_chars: int = 24000
    desktop_task_timeout_seconds: int = 1800
    local_ai_enabled: bool = True
    local_ai_model_path: str = str(LOCAL_AI_MODEL_DIR)
    local_ai_large_model_enabled: bool = True
    local_ai_large_model_path: str = str(LOCAL_AI_LARGE_MODEL_DIR)
    local_ai_timeout_seconds: int = 90
    local_ai_idle_unload_seconds: int = 60
    local_ai_large_idle_unload_seconds: int = 30
    local_ai_large_min_reclaimable_gb: float = 6.0
    apple_foundation_models_enabled: bool = True
    apple_foundation_model_timeout_seconds: int = 30
    private_mode: bool = False
    spoken_responses_enabled: bool = True
    neural_voice_enabled: bool = True
    neural_voice_speed: float = 0.94
    neural_voice_max_chars: int = 800
    follow_up_window_seconds: int = 8
    event_engine_enabled: bool = True
    proactive_actions_enabled: bool = False
    quiet_hours_start: str = "22:00"
    quiet_hours_end: str = "07:00"
    transcription_fallback_enabled: bool = True
    transcription_fallback_command: str = DEFAULT_TRANSCRIPTION_FALLBACK_COMMAND
    visual_fallback_enabled: bool = True
    visual_fallback_command: str = DEFAULT_VISUAL_FALLBACK_COMMAND
    project_index_enabled: bool = True
    project_index_roots: tuple[str, ...] = (str(JARVIS_ROOT / "Code"),)
    trading_journal_enabled: bool = True
    model_memory_headroom_gb: float = 6.0
    large_model_min_battery_percent: int = 30
    prompt_cache_max_tokens: int = 2048
    deep_conversation_enabled: bool = True
    conversation_memory_turns: int = 500
    conversation_context_turns: int = 12
    conversation_relevant_turns: int = 8
    local_ai_active_memory_budget_gb: float = 5.0
    retain_voice_recordings: bool = False
    retain_screen_captures: bool = True
    redact_cloud_handoffs: bool = True


def ensure_dirs() -> None:
    for path in (
        JARVIS_ROOT,
        DATA_DIR,
        INFORMATION_DIR,
        SCREENSHOT_DIR,
        EXPORT_DIR,
        INBOX_DIR,
        TRADING_CHART_DIR,
        INFORMATION_DIR / "Trading" / "Trade Journal",
        INFORMATION_DIR / "Personal Notes",
        INFORMATION_DIR / "Project Notes",
        DATA_DIR / "bin",
        DATA_DIR / "logs",
        DATA_DIR / "backups",
        DATA_DIR / "runtime",
        DATA_DIR / "runtime" / "events",
        DATA_DIR / "runtime" / "transactions",
        DATA_DIR / "runtime" / "transcription",
        DATA_DIR / "runtime" / "vision",
        DATA_DIR / "runtime" / "tts",
        MODELS_DIR,
        MODELS_DIR / "JarvisVoice",
    ):
        path.mkdir(parents=True, exist_ok=True)
        if not path.is_symlink():
            try:
                path.chmod(PRIVATE_DIRECTORY_MODE)
            except OSError:
                pass


def load_config() -> JarvisConfig:
    ensure_dirs()
    if not CONFIG_PATH.exists():
        cfg = JarvisConfig()
        save_config(cfg)
        return cfg
    try:
        raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception:
        return JarvisConfig()
    base = asdict(JarvisConfig())
    base.update({k: v for k, v in raw.items() if k in base})
    return JarvisConfig(**base)


def save_config(config: JarvisConfig) -> None:
    ensure_dirs()
    CONFIG_PATH.write_text(json.dumps(asdict(config), indent=2), encoding="utf-8")
    CONFIG_PATH.chmod(PRIVATE_FILE_MODE)


def installed_root() -> Path:
    marker = DATA_DIR / "install_path"
    if marker.exists():
        value = marker.read_text(encoding="utf-8").strip()
        if value:
            return Path(os.path.expanduser(value))
    return JARVIS_ROOT / "Code"
