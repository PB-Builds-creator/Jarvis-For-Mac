# AI-assisted engineering disclosure

Jarvis was developed with extensive AI assistance. That fact is part of the engineering story, not something this project hides.

## Human-owned work

The project owner supplied the product direction, real operating constraints, privacy and safety boundaries, acceptance criteria, daily-use feedback, hardware testing, and final decisions. Examples include the requirement to share the microphone with Siri, prefer an external input device, work over background media, restore TradingView state after every scan, require confirmation for consequential actions, and prohibit trade execution.

## AI-assisted work

AI tools helped research platform behavior, inspect and modify code, generate implementation alternatives, trace failures, write tests, refactor prompts and policy, and draft documentation. The current system is the result of repeated implementation-and-verification cycles rather than a single generated prompt or untouched template.

## Verification standard

No AI-generated result is accepted solely because it looks plausible. Changes are checked with automated tests, build/signature verification, log evidence, permission-aware live tests, and explicit reporting of anything that remains unverified.

## How to describe this project accurately

An accurate interview explanation is:

> I designed the product requirements, architecture constraints, safety model, and acceptance tests for a local-first macOS assistant, and used AI coding tools as implementation collaborators. I iterated from real failures, reviewed the resulting code and behavior, and required automated and hardware evidence before accepting changes.

Do not claim that every line was typed manually. Do not claim autonomous AI authorship either. The relevant skill demonstrated here is directing a complex AI-assisted engineering process while maintaining requirements, safety boundaries, and evidence.
