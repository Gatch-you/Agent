# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This repository is in the pre-implementation / planning stage: no application code exists yet (only this file and an empty `README.md`). There are no build, lint, or test commands to document yet — add them here as soon as the corresponding tooling is scaffolded, so this section doesn't go stale.

## Vision

The long-term goal is a personal multi-function agent, controlled primarily by voice through a native client. Planned capabilities beyond the initial phase include controlling local/smart-home products (e.g. SwitchBot) and other integrations, added incrementally as new "skills" behind the same voice interface.

**Phase 1 (current focus):** an English-speaking practice system — the user speaks English, an AI converses with them and helps them practice, via the native client's voice input/output.

## Planned architecture

- **Client:** a native mobile app (React Native + Expo) responsible for voice input/output and the conversational UI. This is the single entry point end users interact with, and it is expected to grow new screens/features as new agent skills are added, not be replaced by them.
- **Backend:** planned to be a Go service, if/when backend logic is needed beyond calling an AI API directly from the client. When built, it should follow DDD with an onion (hexagonal-style) architecture — domain logic at the core, with adapters at the edges for things like the AI conversation provider, and later, integrations such as SwitchBot. This layering matters because the backend is meant to support multiple, unrelated "skills" (English learning today, smart-home control and others later) without those skills' infrastructure concerns leaking into shared domain logic.

Keep this document in sync as these pieces are actually built: replace this section with the real module/package layout once the client and/or backend exist, and add the concrete run/build/test/lint commands at that point.
