from __future__ import annotations

import unittest

import numpy as np

from jarvis.tts import (
    PRIMARY_REFERENCE_TEXT,
    PRIMARY_VOICE_INSTRUCTION,
    _cinematic_voice_mix,
    _phoneme_chunks,
    _text_chunks,
    phonemize_british,
    speech_status,
)


class SpeechTests(unittest.TestCase):
    def test_strategy_vocabulary_has_stable_british_pronunciations(self) -> None:
        phonemes = phonemize_british(
            "Jarvis, tell the owner that TradingView MGC and DXY show VWAP."
        )

        self.assertIn("dʒˈɑːvɪs", phonemes)
        self.assertIn("ˌɛm dʒˌiː sˈiː", phonemes)
        self.assertIn("vˈiː wˌɒp", phonemes)

    def test_status_documents_on_demand_resource_and_identity_policy(self) -> None:
        status = speech_status()

        self.assertTrue(status["loads_on_demand"])
        self.assertEqual(status["resident_ram_while_idle_mb"], 0)
        self.assertFalse(status["licensed_voice_clone"])
        self.assertEqual(status["model_license"], "Apache-2.0")
        self.assertIn("primary_ready", status)
        self.assertIn("designed_reference_ready", status)
        self.assertIn("preset_fallback_ready", status)
        self.assertIn("lightweight_fallback_ready", status)

    def test_primary_profile_explicitly_requires_native_british_pronunciation(self) -> None:
        self.assertIn("unmistakably native modern Received Pronunciation", PRIMARY_VOICE_INSTRUCTION)
        self.assertIn("Never sound", PRIMARY_VOICE_INSTRUCTION)
        self.assertIn("American", PRIMARY_VOICE_INSTRUCTION)
        for diagnostic_word in ("armour", "laboratory", "after", "rather"):
            self.assertIn(diagnostic_word, PRIMARY_REFERENCE_TEXT.casefold())

    def test_cinematic_mix_is_bounded_and_preserves_duration(self) -> None:
        source = np.linspace(-0.8, 0.8, 24_000, dtype=np.float32)

        mixed = _cinematic_voice_mix(source)

        self.assertEqual(mixed.shape, source.shape)
        self.assertTrue(np.isfinite(mixed).all())
        self.assertLessEqual(float(np.max(np.abs(mixed))), 0.94)
        self.assertFalse(np.array_equal(mixed, source))

    def test_long_speech_is_split_below_the_model_token_limit(self) -> None:
        chunks = _phoneme_chunks(("dʒˈɑːvɪs " * 180).strip())

        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(0 < len(chunk) <= 480 for chunk in chunks))

    def test_natural_voice_text_chunks_preserve_words_and_limits(self) -> None:
        original = (
            "The five-minute chart is holding VWAP. "
            "The fifteen-minute chart remains balanced, so wait for confirmation. "
        ) * 5
        chunks = _text_chunks(original.strip(), limit=120)

        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(0 < len(chunk) <= 120 for chunk in chunks))
        self.assertEqual(" ".join(chunks).split(), original.split())
