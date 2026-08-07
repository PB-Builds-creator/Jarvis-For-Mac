from __future__ import annotations

import json
import math
import statistics
import subprocess
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Iterable

from .config import OWNER_VOICE_MODEL_PATH, VOICEPRINT_HELPER
from .privacy import delete_keychain_secret, get_keychain_secret, keychain_status, set_keychain_secret


PROFILE_SECRET_NAME = "owner-voice-profile"
PROFILE_VERSION = 1
MIN_ENROLLMENT_SAMPLES = 5
EMBEDDING_SIZE = 256
# WeSpeaker scores drift materially between a clean five-sentence enrollment
# and a short wake phrase recorded over room audio. Keep a strong margin above
# observed non-owner room speech while avoiding a profile-specific threshold
# that rejects the enrolled owner in normal use.
MAX_EFFECTIVE_SIMILARITY_THRESHOLD = 0.68
REFERENCE_TOLERANCE = 0.10
REQUIRED_REFERENCE_MATCHES = 2
# A second, still profile-anchored tier handles short commands and far-field
# recordings. It requires agreement with multiple enrollment references rather
# than accepting a low centroid score on its own.
DISTANT_VOICE_SIMILARITY_THRESHOLD = 0.58
DISTANT_VOICE_REFERENCE_TOLERANCE = 0.10
DISTANT_VOICE_REQUIRED_REFERENCE_MATCHES = 2
# Pitch is only a secondary "regular voice" signal. Values at the edge of the
# detector's supported range are usually autocorrelation harmonics, not a
# person's fundamental frequency. Never let that noisy signal veto a strong
# speaker embedding match.
MIN_RELIABLE_PITCH_HZ = 65.0
MAX_RELIABLE_PITCH_HZ = 330.0


class OwnerVoiceError(RuntimeError):
    pass


@dataclass(frozen=True)
class VoiceSample:
    embedding: tuple[float, ...]
    duration_seconds: float
    voiced_seconds: float
    pitch_hz: float
    pitch_spread: float


def _unit(values: Iterable[float]) -> tuple[float, ...]:
    vector = tuple(float(value) for value in values)
    magnitude = math.sqrt(sum(value * value for value in vector))
    if len(vector) != EMBEDDING_SIZE or not math.isfinite(magnitude) or magnitude <= 1e-8:
        raise OwnerVoiceError("The speaker model returned an invalid voice signature.")
    return tuple(value / magnitude for value in vector)


def _similarity(left: Iterable[float], right: Iterable[float]) -> float:
    return sum(a * b for a, b in zip(left, right, strict=True))


def _extract(path: Path) -> VoiceSample:
    if not VOICEPRINT_HELPER.is_file() or not OWNER_VOICE_MODEL_PATH.is_dir():
        raise OwnerVoiceError("The local owner-voice model is not installed.")
    if not path.is_file():
        raise OwnerVoiceError("The voice sample is missing.")
    result = subprocess.run(
        [
            str(VOICEPRINT_HELPER),
            "extract",
            str(OWNER_VOICE_MODEL_PATH),
            str(path),
        ],
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    try:
        payload = json.loads(result.stdout)
    except Exception as exc:
        raise OwnerVoiceError("The local speaker model returned an unreadable result.") from exc
    if result.returncode != 0 or not payload.get("ok"):
        raise OwnerVoiceError(str(payload.get("error") or "The voice sample could not be analyzed."))
    return _sample_from_payload(payload)


def _sample_from_payload(payload: dict[str, Any]) -> VoiceSample:
    return VoiceSample(
        embedding=_unit(payload.get("embedding", [])),
        duration_seconds=float(payload.get("duration_seconds", 0)),
        voiced_seconds=float(payload.get("voiced_seconds", 0)),
        pitch_hz=float(payload.get("pitch_hz", 0)),
        pitch_spread=float(payload.get("pitch_spread", 0)),
    )


def _extract_many(paths: Iterable[Path]) -> list[VoiceSample]:
    materialized = [Path(path) for path in paths]
    if not VOICEPRINT_HELPER.is_file() or not OWNER_VOICE_MODEL_PATH.is_dir():
        raise OwnerVoiceError("The local owner-voice model is not installed.")
    if not materialized or any(not path.is_file() for path in materialized):
        raise OwnerVoiceError("One or more voice samples are missing.")
    result = subprocess.run(
        [
            str(VOICEPRINT_HELPER),
            "extract-batch",
            str(OWNER_VOICE_MODEL_PATH),
            *(str(path) for path in materialized),
        ],
        text=True,
        capture_output=True,
        timeout=60,
        check=False,
    )
    try:
        payload = json.loads(result.stdout)
    except Exception as exc:
        raise OwnerVoiceError("The local speaker model returned an unreadable result.") from exc
    if result.returncode != 0 or not payload.get("ok"):
        raise OwnerVoiceError(str(payload.get("error") or "The voice samples could not be analyzed."))
    raw_samples = payload.get("samples")
    if not isinstance(raw_samples, list) or len(raw_samples) != len(materialized):
        raise OwnerVoiceError("The speaker model returned an incomplete enrollment.")
    return [_sample_from_payload(sample) for sample in raw_samples]


def _median(values: Iterable[float]) -> float:
    materialized = [float(value) for value in values if math.isfinite(float(value))]
    return statistics.median(materialized) if materialized else 0.0


def _profile() -> dict[str, Any] | None:
    raw = get_keychain_secret(PROFILE_SECRET_NAME)
    if not raw:
        return None
    try:
        payload = json.loads(raw)
        if payload.get("version") != PROFILE_VERSION:
            return None
        _unit(payload.get("centroid", []))
        return payload
    except Exception:
        return None


def _pitch_is_reliable(pitch_hz: float) -> bool:
    return (
        math.isfinite(pitch_hz)
        and MIN_RELIABLE_PITCH_HZ <= pitch_hz <= MAX_RELIABLE_PITCH_HZ
    )


def owner_voice_status() -> dict[str, Any]:
    profile = _profile()
    stored_threshold = (
        float(profile.get("similarity_threshold", 0))
        if profile else 0.0
    )
    return {
        "available": VOICEPRINT_HELPER.is_file() and OWNER_VOICE_MODEL_PATH.is_dir(),
        "enabled": profile is not None,
        "enrolled_samples": int(profile.get("sample_count", 0)) if profile else 0,
        "strictness": (
            "two_tier_regular_voice_with_distant_mic_tolerance"
            if profile else "not_enrolled"
        ),
        "effective_similarity_threshold": (
            round(
                min(stored_threshold, DISTANT_VOICE_SIMILARITY_THRESHOLD),
                3,
            )
            if profile else None
        ),
        "voice_style_check_required": bool(
            profile
            and _pitch_is_reliable(float(profile.get("pitch_center_hz", 0)))
        ),
        "model": "WeSpeaker v2 Core ML int8",
        "compute": "CPU and Apple Neural Engine on demand",
        "profile_storage": "macOS Keychain",
        "raw_audio_retained": False,
        "touch_id_still_required_for_credentials": True,
        "keychain_configured": bool(keychain_status(PROFILE_SECRET_NAME)["configured"]),
    }


def enroll_owner_voice(paths: Iterable[Path]) -> dict[str, Any]:
    samples = _extract_many(paths)
    if len(samples) < MIN_ENROLLMENT_SAMPLES:
        raise OwnerVoiceError(f"Record at least {MIN_ENROLLMENT_SAMPLES} owner-voice samples.")
    if any(sample.voiced_seconds < 0.65 for sample in samples):
        raise OwnerVoiceError("One sample contained too little natural speech. Record it again.")
    embeddings = [sample.embedding for sample in samples]
    centroid = _unit(
        sum(embedding[index] for embedding in embeddings)
        for index in range(EMBEDDING_SIZE)
    )
    centroid_scores = [_similarity(embedding, centroid) for embedding in embeddings]
    pair_scores = [
        _similarity(embeddings[left], embeddings[right])
        for left in range(len(embeddings))
        for right in range(left + 1, len(embeddings))
    ]
    if min(centroid_scores) < 0.48 or _median(pair_scores) < 0.52:
        raise OwnerVoiceError(
            "The samples did not sound like one consistent regular speaking voice. "
            "Use the same microphone, distance, and natural voice, then enroll again."
        )

    # Strict enough to reject unrelated speakers, but calibrated below the
    # least-similar clean enrollment sample to tolerate normal day-to-day drift.
    similarity_threshold = max(
        0.64,
        min(MAX_EFFECTIVE_SIMILARITY_THRESHOLD, min(centroid_scores) - 0.10),
    )
    pitches = [
        sample.pitch_hz for sample in samples
        if _pitch_is_reliable(sample.pitch_hz)
    ]
    pitch_center = _median(pitches)
    pitch_log_deviations = (
        [abs(math.log(pitch / pitch_center)) for pitch in pitches]
        if pitch_center > 0 else []
    )
    # A regular-voice style check intentionally rejects a substantially altered
    # pitch while allowing ordinary morning/evening variation.
    pitch_tolerance_log = max(
        0.13,
        min(0.24, (_median(pitch_log_deviations) * 4.0) + 0.055),
    )
    profile: dict[str, Any] = {
        "version": PROFILE_VERSION,
        "created_at": datetime.now(UTC).isoformat(),
        "sample_count": len(samples),
        "centroid": list(centroid),
        "references": [list(embedding) for embedding in embeddings],
        "similarity_threshold": similarity_threshold,
        "pitch_center_hz": pitch_center,
        "pitch_tolerance_log": pitch_tolerance_log,
        "model": "wespeaker_v2_coreml_int8",
    }
    set_keychain_secret(PROFILE_SECRET_NAME, json.dumps(profile, separators=(",", ":")))
    return {
        "ok": True,
        "enabled": True,
        "sample_count": len(samples),
        "calibrated_threshold": round(similarity_threshold, 4),
        "regular_pitch_hz": round(pitch_center, 1) if pitch_center else None,
        "raw_audio_retained": False,
    }


def verify_owner_voice(path: Path) -> dict[str, Any]:
    profile = _profile()
    if profile is None:
        return {
            "ok": True,
            "enabled": False,
            "accepted": True,
            "reason": "not_enrolled",
        }
    sample = _extract(path)
    centroid = _unit(profile["centroid"])
    references = [_unit(value) for value in profile.get("references", [])]
    centroid_score = _similarity(sample.embedding, centroid)
    reference_scores = sorted(
        (_similarity(sample.embedding, reference) for reference in references),
        reverse=True,
    )
    stored_threshold = float(profile["similarity_threshold"])
    threshold = min(stored_threshold, MAX_EFFECTIVE_SIMILARITY_THRESHOLD)
    strict_reference_floor = threshold - REFERENCE_TOLERANCE
    strict_required = min(REQUIRED_REFERENCE_MATCHES, len(reference_scores))
    strict_matches = sum(score >= strict_reference_floor for score in reference_scores)
    strong_speaker_match = (
        centroid_score >= threshold
        and strict_matches >= strict_required
    )
    distant_threshold = min(stored_threshold, DISTANT_VOICE_SIMILARITY_THRESHOLD)
    distant_reference_floor = (
        distant_threshold - DISTANT_VOICE_REFERENCE_TOLERANCE
    )
    distant_required = min(
        DISTANT_VOICE_REQUIRED_REFERENCE_MATCHES,
        len(reference_scores),
    )
    distant_matches = sum(
        score >= distant_reference_floor for score in reference_scores
    )
    distant_speaker_match = (
        centroid_score >= distant_threshold
        and distant_matches >= distant_required
    )
    speaker_match = strong_speaker_match or distant_speaker_match
    match_tier = "strong" if strong_speaker_match else "distant" if speaker_match else "none"
    reported_threshold = threshold if strong_speaker_match else distant_threshold
    reference_matches = strict_matches if strong_speaker_match else distant_matches
    required_references = strict_required if strong_speaker_match else distant_required

    pitch_center = float(profile.get("pitch_center_hz", 0))
    pitch_tolerance = float(profile.get("pitch_tolerance_log", 0.18))
    pitch_check_reliable = (
        _pitch_is_reliable(pitch_center)
        and _pitch_is_reliable(sample.pitch_hz)
    )
    if pitch_check_reliable:
        pitch_delta = abs(math.log(sample.pitch_hz / pitch_center))
        regular_voice_match = pitch_delta <= pitch_tolerance
    else:
        pitch_delta = 0.0
        regular_voice_match = True
    accepted = speaker_match and regular_voice_match
    reason = (
        "owner_regular_voice"
        if accepted
        else "voice_style_mismatch"
        if speaker_match
        else "speaker_mismatch"
    )
    return {
        "ok": True,
        "enabled": True,
        "accepted": accepted,
        "reason": reason,
        "similarity": round(centroid_score, 4),
        "threshold": round(reported_threshold, 4),
        "match_tier": match_tier,
        "reference_matches": reference_matches,
        "reference_required": required_references,
        "regular_voice_match": regular_voice_match,
        "pitch_check_reliable": pitch_check_reliable,
        "observed_pitch_hz": round(sample.pitch_hz, 1) if sample.pitch_hz > 0 else None,
        "pitch_delta": round(pitch_delta, 4),
        "raw_audio_retained": False,
    }


def disable_owner_voice() -> dict[str, Any]:
    delete_keychain_secret(PROFILE_SECRET_NAME)
    return {
        "ok": True,
        "enabled": False,
        "profile_deleted": True,
        "raw_audio_retained": False,
    }
