# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this package is

`ai_broker` is a pure-Dart package (no Flutter) with two halves that ship together:

1. A provider-agnostic wrapper around LLM HTTP APIs (OpenAI, Anthropic, Gemini) and Google Cloud Translation, behind **capability-split** interfaces: `ChatBroker`, `EmbedBroker`, `TranslateBroker` — each provider implements only the ones its service actually supports.
2. A RAG layer (`SentenceWindowChunker`, `Embedder`, `CorpusStore`) plus a CLI (`bin/ai_broker.dart` → executables `ai_broker` and `aib`) that uses the brokers to ingest text into a local SQLite vector store, search it, answer questions grounded in the results, and translate text.

`README.md` is the public-facing pitch + quick start; `doc/cli.md` is the full CLI reference. Mirror non-trivial API changes there.

## Architecture (read before editing)

```
lib/src/
  core/
    broker.dart                — AiBroker base, AiBrokerRegistry (with lookupAs<T>), AiBrokerException
    key_resolver.dart          — Env / Map / File / Chained resolvers; MissingKeyException
    retry.dart                 — shared 429/503/529 backoff (retryRequest)
    sse.dart                   — shared SSE parser (Gemini uses ?alt=sse)
    code_fence.dart            — stripCodeFence() post-processor

  chat/
    chat_broker.dart           — ChatBroker interface (complete / chat / chatDetailed /
                                 stream / streamDetailed)
    completion.dart            — AiCompletion / StreamedCompletion / AiStopReason / AiEffort
    json_schema.dart           — toGeminiSchema / toOpenAiStrictSchema (pure, no I/O)
    message.dart               — ChatRequest / AiMessage (system is on ChatRequest, not a role)

  embed/
    embed_broker.dart          — EmbedBroker interface
    embedder.dart              — higher-level batcher (count + char budget)

  translate/
    translate_broker.dart      — TranslateBroker interface + TranslationResult
    llm_translator.dart        — wraps any ChatBroker as a TranslateBroker

  brokers/
    openai_broker.dart         — OpenAiBroker (ChatBroker + EmbedBroker)
    anthropic_broker.dart      — AnthropicBroker (ChatBroker only — no first-party embeddings)
    gemini_broker.dart         — GeminiBroker (ChatBroker + EmbedBroker)
    google_translate_broker.dart — GoogleTranslateBroker (TranslateBroker only; Cloud Translation v2)

  rag/
    chunker.dart               — Chunker + SentenceWindowChunker (char-based sliding window)
    text_chunk.dart            — TextChunk value type
    corpus_store.dart          — SQLite-backed store (collections / documents / chunks); cosine top-K

  cli/
    runner.dart                — buildAibRunner(), brokerForId(), addKeyArgs(), resolverFromArgs(),
                                 defaultChatModelFor(), defaultWorkbenchDbPath()
    ingest_command.dart        — IngestCommand
    search_command.dart        — SearchCommand
    ask_command.dart           — AskCommand (RAG: retrieve → ground → chat)
    translate_command.dart     — TranslateCommand
    collections_command.dart   — CollectionsCommand
```

### Capability-split brokers (0.3.0+)

`AiBroker` is the base — `id`, `label`, `listModels` only. Capabilities live on separate interfaces in per-modality folders:

| Provider | Implements |
|----------|-----------|
| `OpenAiBroker` | `ChatBroker` + `EmbedBroker` |
| `AnthropicBroker` | `ChatBroker` |
| `GeminiBroker` | `ChatBroker` + `EmbedBroker` |
| `GoogleTranslateBroker` | `TranslateBroker` (no chat models — `listModels` returns `[]`) |
| `LlmTranslator` | `TranslateBroker` — wraps any `ChatBroker` so chat models can translate |

Why split: no `UnsupportedError` stubs — the type system enforces "you can only call `embed` on something that's actually an `EmbedBroker`". Use `AiBrokerRegistry.lookupAs<T>(id)` for capability-typed lookup; it returns `null` when the broker doesn't implement `T`. **This is breaking vs 0.2.x** — `broker.chat(...)` against a variable typed as `AiBroker` no longer compiles; either declare the variable as the capability type, cast, or use `lookupAs`.

Wire shape: `complete` is just `chat` with a single `AiMessage.user(...)` — the default implementation lives on `ChatBroker`. `stream` events are *incremental deltas*; concatenating them yields the same string `chat` returns.

The CLI is built on these same library types — anything the CLI does, an app importing the library can do. CLI commands accept `brokerFactory` + `keyResolver` constructor parameters specifically as test seams so they never hit a real provider.

Things deliberately *not* in this package — do not add without a real consumer asking:
- No safety / SQL gate. Prompt sanitisation, output filtering, content moderation — call-site concern.
- No tools / function calling.
- No reranker in the RAG layer — cosine top-K only. Add cross-encoder / Cohere Rerank at the call site if quality demands it.
- No Flutter widgets. Build pickers / chat UIs / settings dialogs on top in the consuming app.
- No web support for the RAG layer. `CorpusStore` depends on native `package:sqlite3`. The chat / embed / translate APIs are pure Dart and work on web; the storage layer is native-only today.

### Per-provider gotchas

When editing or adding a broker, mind these — they're the things that diverge across providers:

- **System prompt placement.** OpenAI: `role:system` message. Anthropic: top-level `system` field. Gemini: top-level `systemInstruction` object. Keep `system` out of `ChatRequest.messages` — it's a top-level field on `ChatRequest`.
- **`listModels` filtering.** Each broker filters the catalog so picker UIs don't see embeddings / whisper / dall-e. OpenAI: `^(gpt-|o\d)`. Anthropic: no filter (sorted descending so newest claude lands first). Gemini: must start with `gemini-` and support `generateContent`; paginated up to 5×50. `GoogleTranslateBroker.listModels` always returns `[]` (v2 has no `/models`).
- **Streaming format.** OpenAI & Anthropic are SSE; Gemini is JSON-array by default and *must* be requested with `?alt=sse` so the shared `decodeSseStream` works. Anthropic uses named SSE events (`content_block_delta`, `message_stop`); OpenAI uses `data: [DONE]` to terminate; Gemini's SSE chunks share the same `candidates → content → parts → text` shape as the non-streaming response, so one extractor handles both.
- **Streamed accounting.** `stream` is `streamDetailed(...).deltas` on both streaming brokers — one parse path, so anything added to the read loop shows up in both. Anthropic takes usage from `message_start` (input + cache counts, serving model) and `message_delta` (stop reason, final output count); Gemini from `usageMetadata` + `finishReason` on the chunks. The read loops end in `yield*`, **not** `await for`: an `await for` leaves the generator parked on an await, where a consumer's `subscription.cancel()` hangs until the next byte arrives and the `finally` that settles the completion never runs. The cost of `yield*` is that stream errors bypass the enclosing `catch`, hence the `handleError` hop that fails the completion before re-throwing.
- **Structured output (`ChatRequest.jsonSchema`).** All three chat brokers
  honour it, in three different dialects, and the providers want *opposite*
  things from the same schema. Anthropic takes JSON Schema verbatim in
  `output_config.format`. Gemini takes an **OpenAPI 3.0 subset** in
  `generationConfig.responseSchema` where `additionalProperties` is a hard 400
  (`Unknown name "additionalProperties" at
  'generation_config.response_schema'`) and nullability is a `nullable` flag,
  not a `['string', 'null']` union. OpenAI's `strict` mode **requires**
  `additionalProperties: false` on every object plus every property named in
  `required`. `lib/src/chat/json_schema.dart` holds both translations as pure
  functions — put dialect knowledge there, not in a broker. `toGeminiSchema`
  returns null when a schema has no safe translation (recursive/unresolvable
  `$ref`, a real multi-type union); the broker then sends
  `responseMimeType: 'application/json'` alone, because unconstrained JSON
  beats both prose and a 400. Every broker builds its payload in one
  `@visibleForTesting buildPayload`, shared by the streaming and
  non-streaming paths — keep it that way so the two cannot diverge.
- **Retry policy.** Use `retryRequest` for every non-streaming call. Pass `isHardFailure` when a status code can mean either "retry" or "give up" — currently only OpenAI 429 (`quota` in body) needs this. SSE calls bypass retry (mid-stream restart isn't sound).
- **Embed per-call limits.** OpenAI `text-embedding-3-*`: ≤2048 inputs, ≤300k tokens per request, ≤8191 tokens each. Gemini `text-embedding-004`: ≤100 per call. The broker just forwards the list — use the higher-level `Embedder` to batch.
- **Google Translate glossary.** Cloud Translation v2 doesn't expose v3's server-side glossary resource, so `GoogleTranslateBroker` implements glossary client-side via `<span translate="no">…</span>` HTML wrapping with `format: 'html'`. Source text + glossary targets are HTML-escaped before sending; entities in the response are decoded back. Matching is exact, case-sensitive, substring — provide every casing you care about and use distinctive terms. On overlap the longer key wins; otherwise the earliest match wins. `domain` / `tone` / `context` hints are silently accepted but ignored by v2 — use `LlmTranslator` when they matter.
- **Errors.** All broker-layer failures throw `AiBrokerException` (with optional `statusCode`). Don't leak provider-specific exception types out of the package.

## Internal import convention

Files under `lib/src/` import the package umbrella as `import '/_common.dart';` (absolute, not relative). `_common.dart` re-exports the third-party APIs the package uses (`http`, `meta`, `dart:async` / `convert` / `io`) plus the generated barrel. Add new ambient imports there, not per-file.

`lib/src/_index.g.dart` is **generated** by `df_generate_dart_indexes` — do not hand-edit; add new files to `lib/src/` (in any sub-folder) and the generator picks them up. `lib/ai_broker.dart` re-exports it as the package's public surface.

## Common commands

```sh
dart pub get
dart analyze
dart format .
dart fix --apply

dart test                                          # all tests
dart test test/core/sse_test.dart                  # single file (note new core/ path)
dart test test/cli/                                # one subdirectory (CLI tests only)
dart test --plain-name "decodes"                   # single test by name
dart pub publish --dry-run

# Library example (needs a real API key in env):
ANTHROPIC_API_KEY=sk-... dart run example/lib/example.dart anthropic
OPENAI_API_KEY=sk-...    dart run example/lib/example.dart openai gpt-4o-mini
GEMINI_API_KEY=...       dart run example/lib/example.dart gemini gemini-2.5-flash

# CLI from this checkout (no install needed):
dart run bin/ai_broker.dart ingest    --collection handbook --ext .md docs/
dart run bin/ai_broker.dart search    --collection handbook "key rotation"
dart run bin/ai_broker.dart ask       --collection handbook "How do I rotate the API key?"
dart run bin/ai_broker.dart translate --to es "Hello, world"
dart run bin/ai_broker.dart collections list
```

The CLI auto-loads a `./.env` for keys, so a `.env` at the repo root with `OPENAI_API_KEY=…` / `ANTHROPIC_API_KEY=…` / `GEMINI_API_KEY=…` / `GOOGLE_TRANSLATE_API_KEY=…` is the easiest dev setup (the file is gitignored).

`pubspec.yaml` registers two executables: `ai_broker` (primary) and `aib` (alias). After `dart pub global activate ai_broker` both land on PATH.

## Tests

Tests live under `test/` mirroring `lib/src/` — subdirectories for each modality (`core/`, `chat/`, `embed/`, `translate/`, `brokers/`, `rag/`, `cli/`). One `*_test.dart` per source file; follow this naming so the layout stays scannable. Tests use fake brokers / injected `http.Client` / in-memory `CorpusStore.openInMemory()` — never hit a real provider or touch disk in unit tests. The CLI commands accept `brokerFactory` + `keyResolver` constructor parameters specifically as test seams.

## Editing notes

- Every Dart file starts with a license banner (the `//.title` … `//.title~` block). Preserve it on edits and include it in new files.
- `pubspec.yaml` `description` is the short form required by pub.dev / pana (≤180 chars). Don't expand it; expand `README.md` instead.
- Local artifacts that must not ship to git: `.env`, `.env.*`, `*.db` / `*.db-*`. Already in `.gitignore`. The default workbench DB lives at `~/.ai_broker/corpus.db` (override with `$AIB_DB`); the in-repo `embeddings/corpus.db*` is a local dev scratch and ignored too.
- Release flow: commit-prefix `+` triggers a CI version bump, `++` also publishes to pub.dev. Bump `CHANGELOG.md` in the same commit.
- Adding a new provider: drop the broker file in `lib/src/brokers/`, implement only the capability interfaces (`ChatBroker` / `EmbedBroker` / `TranslateBroker`) the service actually supports — no `UnsupportedError` stubs. Wire it into `brokerForId()` in `lib/src/cli/runner.dart` so the CLI can resolve it.
- Adding a new capability (image / TTS / vision / …): create a new sibling folder under `lib/src/` (e.g. `lib/src/image/`) with the interface in `image_broker.dart` plus any helpers. Update relevant brokers to implement it. Keep the modality split — don't extend `AiBroker` itself.
