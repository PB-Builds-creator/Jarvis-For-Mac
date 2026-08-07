# Third-party notices

Jarvis source is licensed under Apache-2.0. Downloaded model weights and Python
packages remain under their own licenses and are not redistributed in this
repository. The installers pin the model revisions listed below.

## Local language models

Jarvis optionally downloads MLX conversions of Qwen3.5 for on-device planning:

- `mlx-community/Qwen3.5-4B-OptiQ-4bit`, revision
  `6cb5bdfd0bf15f484881fb9f1ab6d7c840fddde9`
- `mlx-community/Qwen3.5-9B-4bit`, revision
  `8b2b98c00a6b4d291155e4890773ca8f769aee53`
- Base model family: Qwen3.5
- Model license: Apache License 2.0
- Runtime: Apple MLX, `mlx-lm`, and `mlx-vlm`

Model cards and license terms are downloaded with the model artifacts. Review
them before redistributing weights or derived builds.

## Jarvis Owner Voice

Jarvis optionally uses the `wespeaker_v2` Core ML speaker-embedding model from
`FluidInference/speaker-diarization-coreml`, revision
`1ed7a662fdc7109e36d822db793ee6eebdaf8594`.

- Model repository: https://huggingface.co/FluidInference/speaker-diarization-coreml
- Integration reference: https://github.com/FluidInference/FluidAudio
- Model license: Creative Commons Attribution 4.0 International (CC BY 4.0)
- Original speaker-embedding toolkit: WeSpeaker

Citation:

> Hongji Wang, Chengdong Liang, Shuai Wang, Zhengyang Chen, Binbin Zhang,
> Xu Xiang, Yanlei Deng, and Yanmin Qian. “WeSpeaker: A Research and
> Production Oriented Speaker Embedding Learning Toolkit.” ICASSP 2023.

## Jarvis Cinematic Voice

Jarvis primarily uses the Qwen3-TTS 12Hz 0.6B Base model converted to 8-bit MLX
format by the MLX Community, revision
`50f45ef0047cde7e84c2ef04326acb8ada2436a7`. Its original British assistant
reference was created locally with the Qwen3-TTS 12Hz 1.7B VoiceDesign 5-bit
model, revision `6e936cfb98d95b707bd1f85351874a377230fe83`.

- Runtime model: https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit
- Design model: https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-5bit
- Model license: Apache License 2.0
- Runtime: https://github.com/Blaizzy/mlx-audio (MIT License)

Jarvis uses an original older British gentleman timbre designed for this app.
It does not clone or impersonate any real person or existing character.

### Preset and lightweight fallbacks

The Qwen3-TTS 1.7B CustomVoice 4-bit Ryan timbre, revision
`f35faf19b0cc2160865af64ecf0f22f83d335135`, remains available as the first
fallback.

Jarvis also uses the Kokoro-82M speech model and the `bm_george` British
voice converted for MLX by the MLX Community, revision
`a71e4d38b236d968966a2002c4c895dbd12b1c3c`.

- Model repository: https://huggingface.co/mlx-community/Kokoro-82M-bf16
- Model and voice license: Apache License 2.0
- Runtime: https://github.com/Blaizzy/mlx-audio (MIT License)
- Lightweight British lexicon: https://github.com/hexgrad/misaki (Apache License 2.0)

This feature provides a cinematic British AI style. It does not copy movie
audio or clone or impersonate Paul Bettany or any other actor.

## Python dependencies

Runtime dependency versions are declared in `pyproject.toml` and pinned in
`constraints.txt`. They are installed from their respective distributions and
are not vendored here. Review each distribution's license metadata when
redistributing a bundled application. Major runtimes include Apple MLX,
`mlx-audio`, `mlx-lm`, `mlx-vlm`, Misaki, NumPy, and SoundFile.
