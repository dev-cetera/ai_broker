# CLAUDE.md

## What this package is

Provider-agnostic Dart wrapper around three LLM HTTP APIs (OpenAI, Anthropic, Gemini) behind a single `AiBroker` interface. Pure Dart, no Flutter. The outer workspace's [CLAUDE.md](../../CLAUDE.md) describes the umbrella structure, lint baseline, and `@scripts/` tooling — read it for cross-package conventions.

## Architecture (read before editing)

```
AiBroker (interface)        — broker.dart
  ├── OpenAiBroker          — brokers/openai_broker.dart
  ├── AnthropicBroker       — brokers/anthropic_broker.dart
  └── GeminiBroker          — brokers/gemini_broker.dart

AiBrokerRegistry            — process-wide id → broker map
ChatRequest / AiMessage     — message.dart (system is a top-level field, not a role)
KeyResolver                 — key_resolver.dart (Env/Map, or implement your own)
retryRequest()              — retry.dart (shared 429/503/529 backoff)
decodeSseStream()           — sse.dart (shared SSE parser; Gemini uses ?alt=sse)
stripCodeFence()            — code_fence.dart (post-process model output)
```

Wire shape: every broker implements the same 4 methods (`listModels`, `complete`, `chat`, `stream`). `complete` is just `chat` with a single `AiMessage.user(...)` — the default lives on the interface. `stream` events are *incremental deltas*; concatenating them yields the same string `chat` returns.

Things deliberately *not* in this package — do not add without a real consumer asking:
- No safety/SQL gates (call-site responsibility).
- No persistence (key storage, model preference, history).
- No tools / function calling.
- No Flutter widgets.

### Per-provider gotchas

When editing or adding a broker, mind these — they're the things that diverge across providers:

- **System prompt placement.** OpenAI: `role:system` message. Anthropic: top-level `system` field. Gemini: top-level `systemInstruction` object. Keep `system` out of `ChatRequest.messages`.
- **listModels filtering.** Each broker filters the catalog so picker UIs don't see embeddings/whisper/dall-e. OpenAI: `^(gpt-|o\d)`. Anthropic: no filter (sorted descending so newest claude lands first). Gemini: must start with `gemini-` and support `generateContent`; paginated up to 5×50.
- **Streaming format.** OpenAI & Anthropic are SSE; Gemini is JSON-array by default and *must* be requested with `?alt=sse` so the shared `decodeSseStream` works. Anthropic uses named SSE events (`content_block_delta`, `message_stop`); OpenAI uses `data: [DONE]` to terminate; Gemini's SSE chunks share the same `candidates → content → parts → text` shape as the non-streaming response, so one extractor handles both.
- **Retry policy.** Use `retryRequest` for every non-streaming call. Pass `isHardFailure` when a status code can mean either "retry" or "give up" — currently only OpenAI 429 (`quota` in body) needs this. SSE calls bypass retry (mid-stream restart isn't sound).
- **Errors.** All broker-layer failures throw `AiBrokerException` (with optional `statusCode`). Don't leak provider-specific exception types out of the package.

## Internal import convention

Files under `lib/src/` import the package umbrella as `import '/_common.dart';` (absolute, not relative). `_common.dart` re-exports the third-party APIs the package uses (`http`, `meta`, `dart:async`/`convert`/`io`) plus the generated barrel. Add new ambient imports there, not per-file.

`lib/src/_src.g.dart` is **generated** by `df_generate_dart_indexes` — do not hand-edit; add new files to `lib/src/` and regenerate.

## Common commands

Run inside this package directory:

```sh
dart pub get
dart analyze
dart format .
dart fix --apply
dart test                              # all tests
dart test test/sse_test.dart           # single file
dart test --plain-name "decodes"       # single test by name
dart pub publish --dry-run

# Example CLI (needs a real API key in env):
ANTHROPIC_API_KEY=sk-... dart run example/example.dart anthropic
OPENAI_API_KEY=sk-...    dart run example/example.dart openai gpt-4o-mini
GEMINI_API_KEY=...       dart run example/example.dart gemini gemini-2.5-flash
```

Tests live flat under `test/` (no subdirectory tree). One `*_test.dart` per source file in `lib/src/`. New tests should follow that naming so the layout stays scannable. Tests use stub brokers / injected `http.Client` — never hit a real provider in unit tests.

## Editing notes

- Every Dart file starts with a license banner — preserve it.
- `pubspec.yaml` `description` is the short form required by pub.dev/pana (≤180 chars). Don't expand it; expand `README.md` instead.
- `README.md` is the source of truth for the public-facing pitch and quick-start; mirror non-trivial API changes there.
- Release flow is governed by the workspace `pub.dev_package_workflow` — commit-prefix `+` triggers a CI version bump, `++` also publishes. See the outer CLAUDE.md.
