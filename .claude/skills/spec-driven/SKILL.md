---
name: spec-driven
description: Use this skill whenever implementing a new feature, screen, or behavior change in this repository (client/ app, and any future backend). Drives the project's Spec-Driven Development (SDD) + Test-Driven Development (TDD) workflow — write a spec, track it as a GitHub issue, get it clear, write a failing unit test from it, implement on a branch, then open a PR for review. Triggers on "add a feature", "implement X", "build the Y screen", "spec this out", or any request to write new application behavior. Not for pure refactors, config/tooling changes, or exploratory throwaway code.
---

# Spec-driven development + TDD

This repository builds every feature spec-first, then test-first, tracked as a GitHub issue, and landed through a reviewed PR — never a direct commit to `main`. Follow these phases in order; don't skip to implementation, and don't merge your own PR without the user's explicit approval.

## 1. Write or update the spec

Before writing any implementation code, create or update a Markdown file at `.claude/specs/<feature-slug>.md` (kebab-case, e.g. `.claude/specs/speaking-practice-session.md`). Copy the structure from `.claude/specs/_template.md`.

A spec must be concrete enough to test against:
- **Requirements** as short, testable statements, not vague goals.
- **Acceptance criteria** as a checklist or Given/When/Then list — each one should map to at least one unit test later.
- **Out of scope**, so the feature doesn't silently grow.

If the request is ambiguous or the acceptance criteria aren't yet testable, ask the user (don't guess) and update the spec before moving on. Small, obviously-unambiguous changes can use a short spec — the point is a clear, testable description, not bureaucracy.

## 2. Open a GitHub issue from the spec

Once the spec is concrete, create the tracking issue with the spec as its body:

```bash
gh issue create --title "<feature name>" --label enhancement --body-file .claude/specs/<feature-slug>.md
```

This issue is the task-board entry — open issues are the backlog/in-progress list, closing one (via the PR's `Closes #N`) is how work is marked done. Note the issue number; it drives the branch name and the PR.

## 3. Create a feature branch

Branch off `main` (not off `client`/`design` — those are legacy and shouldn't gain new history): `git checkout main && git pull && git checkout -b feat/<issue-number>-<feature-slug>`.

## 4. Red: write a failing test

For each acceptance criterion, write a unit test first, colocated with the code it tests (Flutter convention: `test/` mirroring `lib/`, e.g. `lib/foo/bar.dart` → `test/foo/bar_test.dart`).

Run `flutter test` and confirm the test fails for the expected reason — not a typo or import error.

**Note:** there is no automated hook blocking non-TDD edits in this repo (`tdd-guard` was evaluated and dropped — no Dart/Flutter reporter exists for it; see root `CLAUDE.md`). This red/green/refactor discipline is enforced by convention only — actually follow it, don't just note it.

## 5. Green: implement the minimum to pass

Write only enough code to make the failing test(s) pass. Don't implement acceptance criteria that don't have a test yet — go back to step 4 for those.

## 6. Refactor

With tests green, clean up (naming, duplication, structure) without changing behavior. Re-run `flutter test` and `flutter analyze` after refactoring.

## 7. Close the loop on the spec

Update the spec file: mark it `Implemented`, and list the source/test files that satisfy each acceptance criterion. Specs are living documents — when behavior changes later, update the spec in the same change, don't leave it stale. Commit this alongside the implementation.

## 8. Open a PR and wait for review

Push the branch and open a PR against `main` referencing the issue (`Closes #N` in the body so merging auto-closes it — see `.github/pull_request_template.md` for the expected shape). Then **stop and wait** — the user reviews on GitHub; don't merge, and don't start the next feature's branch, until they say to proceed. If they request changes, address them as new commits on the same branch/PR rather than opening a new one.
