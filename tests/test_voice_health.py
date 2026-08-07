from __future__ import annotations

import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from jarvis.voice_health import voice_pipeline_health


class VoicePipelineHealthTests(unittest.TestCase):
    def test_private_metrics_report_recovery_and_intent_quality(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "voice.log"
            log.write_text(
                "\n".join((
                    "[2026-07-29T12:00:00Z] wake_restart_failed detail=busy",
                    "[2026-07-29T12:01:00Z] wake_audio_started device=Razer Seiren V3 Mini rate=48000 channels=1",
                    "[2026-07-29T12:02:00Z] wake_inline_command chars=24 words=4",
                    "[2026-07-29T12:02:01Z] voice_intent kind=scan_app_window source=named_window_scan_rule actions=0 interpreted=true reason=fuzzy_known_command",
                    "[2026-07-29T12:03:00Z] command_no_speech updates=0",
                    "[2026-07-29T12:04:00Z] whisper_fallback_completed",
                    "[2026-07-29T12:05:00Z] owner_voice_verification accepted=true reason=owner_regular_voice score=0.811",
                    "[2026-07-29T12:06:00Z] owner_voice_verification accepted=false reason=speaker_mismatch score=0.211",
                    "",
                )),
                encoding="utf-8",
            )
            health = voice_pipeline_health(
                log,
                now=datetime(2026, 7, 29, 13, 0, tzinfo=timezone.utc),
            )

        self.assertEqual(health["status"], "healthy")
        self.assertTrue(health["wake_recovered"])
        self.assertEqual(health["last_device"], "Razer Seiren V3 Mini")
        self.assertEqual(health["recognition_success_rate"], 0.5)
        self.assertEqual(health["intent_match_rate"], 1.0)
        self.assertEqual(health["counts"]["contextual_interpretations"], 1)
        self.assertEqual(health["counts"]["whisper_recoveries"], 1)
        self.assertEqual(health["counts"]["owner_voice_accepted"], 1)
        self.assertEqual(health["counts"]["owner_voice_rejected"], 1)
        self.assertNotIn("scan tradingview", str(health).casefold())

    def test_latest_unrecovered_failure_is_degraded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "voice.log"
            log.write_text(
                "[2026-07-29T12:00:00Z] wake_audio_started device=Razer rate=48000 channels=1\n"
                "[2026-07-29T12:05:00Z] wake_restart_failed detail=busy\n",
                encoding="utf-8",
            )
            health = voice_pipeline_health(
                log,
                now=datetime(2026, 7, 29, 13, 0, tzinfo=timezone.utc),
            )

        self.assertEqual(health["status"], "degraded")
        self.assertFalse(health["wake_recovered"])
        self.assertTrue(health["warnings"])


if __name__ == "__main__":
    unittest.main()
