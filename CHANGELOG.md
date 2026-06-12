# Changelog

## 0.3.0

**Breaking.** `AiBroker` no longer carries `chat` / `stream` / `complete` /
`embed`. Capabilities are split across `ChatBroker`, `EmbedBroker`, and
`TranslateBroker`; each provider implements only the ones it actually
supports. Use `AiBrokerRegistry.lookupAs<T>(id)` for capability-typed
lookup. Code like `broker.chat(...)` against a variable typed as `AiBroker`
no longer compiles — declare the variable as the capability type, cast at
the call site, or use `lookupAs`.

- feat: `EmbedBroker` interface implemented by `OpenAiBroker`
  (`text-embedding-3-*`) and `GeminiBroker` (`text-embedding-004`), plus a
  higher-level `Embedder` that batches inputs by count + char budget.
- feat: `TranslateBroker` interface with two implementations:
  `GoogleTranslateBroker` (Cloud Translation v2; client-side glossary via
  HTML `translate="no"` wrapping with entity decoding on response) and
  `LlmTranslator` (wraps any `ChatBroker`, supports domain / tone /
  glossary / free-form context hints).
- feat: RAG layer — `SentenceWindowChunker`, `CorpusStore` (SQLite-backed,
  cosine top-K, content-hash-idempotent), `TextChunk`.
- feat: CLI shipped as the `ai_broker` and `aib` executables. Subcommands:
  `ingest`, `search`, `ask`, `translate`, `collections`. Keys resolved via
  direct flags → `--env-file` / `./.env` → env vars.
- feat: `FileKeyResolver` and `ChainedKeyResolver` for layered key
  resolution.
- fix: `GoogleTranslateBroker` now decodes the HTML entities Google emits
  in `format: 'html'` responses (previously `&amp;`/`&lt;` leaked into
  translated text when a glossary was supplied), and escapes input text
  + glossary targets before wrapping so `<`/`&` in the source don't
  break the markup.
- fix: `AnthropicBroker.listModels` sorts with a digit-aware comparator
  so `claude-3-10-sonnet` ranks above `claude-3-7-sonnet`.
- fix: `OpenAiBroker` / `AnthropicBroker` no longer send an empty
  `system` field on the wire (parity with `GeminiBroker`).
- fix: `SentenceWindowChunker._hardSplit` no longer slices UTF-16
  surrogate pairs across chunk boundaries.

## 0.2.1

- feat: `stripCodeFence` helper for stripping leading/trailing markdown code
  fences from model output, exported from the package barrel.

## 0.2.0

Initial release. `AiBroker` interface (`listModels`, `complete`, `chat`,
`stream`) with three implementations: `OpenAiBroker`, `AnthropicBroker`,
`GeminiBroker`. `AiBrokerRegistry` for runtime provider lookup.
`KeyResolver` (`EnvKeyResolver`, `MapKeyResolver`) for pluggable key
sourcing. Shared SSE decoder and retry-with-backoff helper.
