---
name: spec-driven
description: Use this skill whenever implementing a new feature, screen, or behavior change in this repository (client/ app, and any future backend). Drives the project's Spec-Driven Development (SDD) + Test-Driven Development (TDD) workflow — write a spec, get it clear, write a failing unit test from it, then implement. Triggers on "add a feature", "implement X", "build the Y screen", "spec this out", or any request to write new application behavior. Not for pure refactors, config/tooling changes, or exploratory throwaway code.
---

# Spec-driven development + TDD

This repository builds every feature spec-first, then test-first. Follow these phases in order; don't skip to implementation.

## 1. Write or update the spec

Before writing any implementation code, create or update a Markdown file at `.claude/specs/<feature-slug>.md` (kebab-case, e.g. `.claude/specs/speaking-practice-session.md`). Copy the structure from `.claude/specs/_template.md`.

A spec must be concrete enough to test against:
- **Requirements** as short, testable statements, not vague goals.
- **Acceptance criteria** as a checklist or Given/When/Then list — each one should map to at least one unit test later.
- **Out of scope**, so the feature doesn't silently grow.

If the request is ambiguous or the acceptance criteria aren't yet testable, ask the user (don't guess) and update the spec before moving on. Small, obviously-unambiguous changes can use a short spec — the point is a clear, testable description, not bureaucracy.

## 2. Red: write a failing test

For each acceptance criterion, write a unit test first, colocated with the code it tests (Flutter convention: `test/` mirroring `lib/`, e.g. `lib/foo/bar.dart` → `test/foo/bar_test.dart`).

Run `flutter test` and confirm the test fails for the expected reason — not a typo or import error.

**Note:** there is no automated hook blocking non-TDD edits in this repo (`tdd-guard` was evaluated and dropped — no Dart/Flutter reporter exists for it; see root `CLAUDE.md`). This red/green/refactor discipline is enforced by convention only — actually follow it, don't just note it.

## 3. Green: implement the minimum to pass

Write only enough code to make the failing test(s) pass. Don't implement acceptance criteria that don't have a test yet — go back to step 2 for those.

## 4. Refactor

With tests green, clean up (naming, duplication, structure) without changing behavior. Re-run `flutter test` and `flutter analyze` after refactoring.

## 5. Close the loop

Update the spec file: mark it `Implemented`, and list the source/test files that satisfy each acceptance criterion. Specs are living documents — when behavior changes later, update the spec in the same change, don't leave it stale.
