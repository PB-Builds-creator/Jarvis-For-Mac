from __future__ import annotations

import json
import math
import unittest
from pathlib import Path
from unittest.mock import patch

from jarvis import owner_voice


def unit(*values: float) -> tuple[float, ...]:
    padded = list(values) + [0.0] * (owner_voice.EMBEDDING_SIZE - len(values))
    magnitude = math.sqrt(sum(value * value for value in padded))
    return tuple(value / magnitude for value in padded)


class OwnerVoiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.secret: str | None = None
        self.samples = [
            owner_voice.VoiceSample(
                embedding=unit(1.0, offset),
                duration_seconds=2.5,
                voiced_seconds=1.8,
                pitch_hz=118.0 + offset,
                pitch_spread=12.0,
            )
            for offset in (-0.07, -0.03, 0.0, 0.04, 0.08)
        ]
        patches = [
            patch.object(
                owner_voice,
                "set_keychain_secret",
                side_effect=lambda _name, value: setattr(self, "secret", value),
            ),
            patch.object(
                owner_voice,
                "get_keychain_secret",
                side_effect=lambda _name: self.secret,
            ),
            patch.object(
                owner_voice,
                "delete_keychain_secret",
                side_effect=lambda _name: setattr(self, "secret", None) or True,
            ),
        ]
        for active_patch in patches:
            active_patch.start()
            self.addCleanup(active_patch.stop)

    def enroll(self) -> None:
        with patch.object(owner_voice, "_extract_many", return_value=self.samples):
            result = owner_voice.enroll_owner_voice(
                Path(f"/tmp/sample-{index}.wav") for index in range(5)
            )
        self.assertTrue(result["enabled"])
        self.assertFalse(result["raw_audio_retained"])

    def test_accepts_owner_and_rejects_other_speaker(self) -> None:
        self.enroll()
        owner_sample = owner_voice.VoiceSample(
            embedding=unit(1.0, 0.02),
            duration_seconds=2.2,
            voiced_seconds=1.5,
            pitch_hz=120.0,
            pitch_spread=11.0,
        )
        with patch.object(owner_voice, "_extract", return_value=owner_sample):
            accepted = owner_voice.verify_owner_voice(Path("/tmp/owner.wav"))
        self.assertTrue(accepted["accepted"])
        self.assertEqual(accepted["reason"], "owner_regular_voice")

        other_speaker = owner_voice.VoiceSample(
            embedding=unit(0.0, 0.0, 1.0),
            duration_seconds=2.2,
            voiced_seconds=1.5,
            pitch_hz=120.0,
            pitch_spread=11.0,
        )
        with patch.object(owner_voice, "_extract", return_value=other_speaker):
            rejected = owner_voice.verify_owner_voice(Path("/tmp/other.wav"))
        self.assertFalse(rejected["accepted"])
        self.assertEqual(rejected["reason"], "speaker_mismatch")

    def test_altered_owner_voice_style_is_rejected(self) -> None:
        self.enroll()
        altered = owner_voice.VoiceSample(
            embedding=unit(1.0, 0.01),
            duration_seconds=2.2,
            voiced_seconds=1.5,
            pitch_hz=175.0,
            pitch_spread=25.0,
        )
        with patch.object(owner_voice, "_extract", return_value=altered):
            result = owner_voice.verify_owner_voice(Path("/tmp/altered.wav"))
        self.assertFalse(result["accepted"])
        self.assertEqual(result["reason"], "voice_style_mismatch")
        self.assertFalse(result["regular_voice_match"])

    def test_invalid_boundary_pitch_never_vetoes_strong_owner_match(self) -> None:
        centroid = unit(1.0, 0.0)
        self.secret = json.dumps(
            {
                "version": 1,
                "sample_count": 5,
                "centroid": centroid,
                "references": [centroid] * 5,
                "similarity_threshold": 0.68,
                "pitch_center_hz": 400.0,
                "pitch_tolerance_log": 0.13,
            }
        )
        owner_sample = owner_voice.VoiceSample(
            embedding=unit(0.76, math.sqrt(1.0 - (0.76 * 0.76))),
            duration_seconds=2.4,
            voiced_seconds=1.7,
            pitch_hz=122.0,
            pitch_spread=11.0,
        )
        with patch.object(owner_voice, "_extract", return_value=owner_sample):
            result = owner_voice.verify_owner_voice(Path("/tmp/owner-room.wav"))
        self.assertTrue(result["accepted"])
        self.assertEqual(result["reason"], "owner_regular_voice")
        self.assertFalse(result["pitch_check_reliable"])
        self.assertFalse(owner_voice.owner_voice_status()["voice_style_check_required"])

    def test_legacy_clean_room_threshold_allows_owner_wake_phrase_drift(self) -> None:
        centroid = unit(1.0, 0.0)
        self.secret = json.dumps(
            {
                "version": 1,
                "sample_count": 5,
                "centroid": centroid,
                "references": [centroid] * 5,
                "similarity_threshold": 0.804,
                "pitch_center_hz": 120.0,
                "pitch_tolerance_log": 0.13,
            }
        )
        owner_wake = owner_voice.VoiceSample(
            embedding=unit(0.72, math.sqrt(1.0 - (0.72 * 0.72))),
            duration_seconds=1.4,
            voiced_seconds=0.9,
            pitch_hz=121.0,
            pitch_spread=11.0,
        )
        with patch.object(owner_voice, "_extract", return_value=owner_wake):
            result = owner_voice.verify_owner_voice(Path("/tmp/owner-wake.wav"))
        self.assertTrue(result["accepted"])
        self.assertEqual(result["threshold"], 0.68)
        self.assertEqual(result["reference_required"], 2)

    def test_distant_short_owner_uses_multi_reference_tolerant_tier(self) -> None:
        self.enroll()
        distant_owner = owner_voice.VoiceSample(
            embedding=unit(0.61, 0.0, math.sqrt(1.0 - (0.61 * 0.61))),
            duration_seconds=1.4,
            voiced_seconds=0.75,
            pitch_hz=121.0,
            pitch_spread=12.0,
        )
        with patch.object(owner_voice, "_extract", return_value=distant_owner):
            result = owner_voice.verify_owner_voice(Path("/tmp/distant-owner.wav"))

        self.assertTrue(result["accepted"])
        self.assertEqual(result["match_tier"], "distant")
        self.assertEqual(result["threshold"], 0.58)
        self.assertGreaterEqual(result["reference_matches"], 2)

    def test_profile_has_no_audio_and_disable_deletes_it(self) -> None:
        self.enroll()
        profile = json.loads(self.secret or "{}")
        self.assertNotIn("audio", profile)
        self.assertNotIn("path", profile)
        disabled = owner_voice.disable_owner_voice()
        self.assertTrue(disabled["profile_deleted"])
        self.assertIsNone(self.secret)

    def test_native_voiceprint_isolates_near_field_speech_without_weakening_gate(
        self,
    ) -> None:
        source = (
            Path(__file__).parents[1] / "native" / "JarvisVoiceprint.swift"
        ).read_text(encoding="utf-8")
        self.assertIn("foregroundWindowFrames = 160", source)
        self.assertIn("activeRatio >= 0.72", source)
        self.assertIn("foregroundContrast >= 1.35", source)
        self.assertIn("foreground * foreground", source)
        self.assertIn("The threshold and", source)
        menu_source = (
            Path(__file__).parents[1] / "native" / "JarvisMenuBar.swift"
        ).read_text(encoding="utf-8")
        self.assertIn("ownerVoiceMaximumEffectiveThreshold = 0.68", menu_source)
        self.assertIn("ownerVoiceReferenceTolerance = 0.10", menu_source)
        self.assertIn("ownerVoiceRequiredReferenceMatches = 2", menu_source)
        self.assertIn("ownerVoiceDistantThreshold = 0.58", menu_source)
        self.assertIn("tier=\\(match.matchTier)", menu_source)
        self.assertIn("ownerVoiceMaximumReliablePitchHz = 330.0", menu_source)
        self.assertIn("owner_voice_wake_deferred_to_full_command", menu_source)
        self.assertIn("YIN's cumulative mean-normalized difference", source)
