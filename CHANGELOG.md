# Changelog

## [0.8.0]

- breaking: `ChatRequest.temperature` is now `double?` (default `null`, was `0.3`) and is sent only when set; current Claude and OpenAI reasoning models reject it. `complete` / `completeWithMeta` take `double? temperature`.
- breaking: a turn with no text no longer throws from `chatWithMeta` / `completeWithMeta`; a refusal or a truncated empty reply is reported (`finishReason`), and only `chat` / `complete` throw.
- breaking: `OpenAiBroker` sends the token ceiling as `max_completion_tokens` (`max_tokens` is deprecated and rejected by o-series models).
- feat: `AiCompletion` gains `model`, `cacheReadInputTokens`, `cacheCreationInputTokens` and `toolCalls`, plus `isRefusal`, `wantsTool` and `isTruncated`. Its constructor now needs only `text`.
- feat: `OpenAiCompatibleBroker(id:, label:, baseUrl:, …)` for any OpenAI-compatible API (OpenRouter, Mistral, Groq, xAI, Ollama, LM Studio, vLLM); `OpenAiBroker` now builds on it.
- feat: `DeepSeekBroker`, chat only; `jsonSchema` is sent as JSON mode with the schema in the system prompt, since DeepSeek has no `json_schema`. `deepseek` is recognised by the key resolvers and the CLI (`--deepseek-key`, `DEEPSEEK_API_KEY`).
- feat: `KeyCheckBroker.checkKey(apiKey)` returns an `AiKeyCheck` that tells `valid`, `invalid`, `unreachable` and `error` apart; implemented by every built-in broker. `checkKeyByRequest` and `isGoogleInvalidKey` are exported for custom brokers.
- feat: `AnthropicBroker(browserAccess: true)` sends `anthropic-dangerous-direct-browser-access`, so a web app can call Claude with the user's own key.
- feat: `ChatRequest.effort` (`AiEffort`) maps to Anthropic `output_config.effort` and to `reasoning_effort` on OpenAI-compatible APIs.
- feat: `ChatRequest.jsonSchema` structured output on all three providers (Anthropic `output_config.format`, OpenAI strict `json_schema`, Gemini `responseSchema`); `toGeminiSchema` and `toOpenAiStrictSchema` are exported.
- feat: tool calling on all three providers: `AiTool`, `ChatRequest.tools` / `toolChoice`, `AiCompletion.toolCalls`, `AiMessage.assistantToolCalls` / `AiMessage.toolResult`, `decodeToolArguments`.
- feat: `ChatRequest.cacheSystem` marks the Anthropic system prompt for prompt caching.
- feat: `streamWithMeta` returns a `StreamedCompletion` whose `completion` carries token counts, the serving model and the finish reason; streams on OpenAI-compatible APIs ask for usage.
- feat: `AnthropicBroker(baseUrl:)` and `ANTHROPIC_BASE_URL` for proxies and gateways.
- fix: constructing `AnthropicBroker` and honouring a `Retry-After` date no longer touch `dart:io`, so both work on the web.
- fix: chat request timeouts raised from 30 s to 120 s for every chat broker; long structured or reasoning replies were cut off.

## [0.5.2]

- fix: The package now compiles for the web (dart2js and dart2wasm). `CorpusStore` imported `package:sqlite3/sqlite3.dart`, which needs `dart:ffi`, and the barrel exports it, so any web app importing `package:ai_broker/ai_broker.dart`, even just for the chat brokers, failed to build. The import is now conditional on `dart.library.ffi`. On the web a stand-in is used and opening a `CorpusStore` throws `UnsupportedError`. Chat, embed and translate work on the web; the RAG store is still native-only. No API change on native.

## [0.5.0]

- chore: standardize README and CI/CD workflows, remove donation links, update contact info and repository links
- chore: resolve analyzer issues

## 0.4.0

Also includes everything in 0.3.0 below (`completeWithMeta` /
`chatWithMeta`, the `stripCodeFence` and `retryRequest` fixes), ported
onto the capability split: the `*WithMeta` methods and the `chat` /
`complete` defaults now live on `ChatBroker`, and the built-in brokers
`extend ChatBroker`. A class that `implements ChatBroker` must supply
`chatWithMeta`.

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

## 0.3.0

Published from the pre-restructure line (before the capability split
above), so in 0.3.0 these methods live on `AiBroker`.

- feat!: `AiBroker.completeWithMeta` / `chatWithMeta` return an
  `AiCompletion` — the text plus the provider's raw finish reason, that
  reason mapped onto the new `AiFinishReason` enum (`null` when unmapped),
  and input / output / thinking token counts. `complete` and `chat` now
  delegate to them and return the same text as before.
- BREAKING: `chatWithMeta` is the one call a broker implements; `chat`,
  `complete` and `completeWithMeta` are defaults on `AiBroker`. A class
  that `implements AiBroker` must add `chatWithMeta`; one that
  `extends AiBroker` may drop its `chat` / `complete` overrides. The three
  built-in brokers now `extend AiBroker`.
- fix: `retryRequest` also retries 500 / 502 / 504 and transient network
  errors (`ClientException`; a `TimeoutException` is deliberately not
  retried, since the provider may still be generating and billing the
  request), and honours
  `Retry-After` (seconds or HTTP-date, capped by the new `maxRetryAfter`,
  default 60 s). The exhausted-retries message now reads
  `still failing (HTTP n) after N attempts`.
- fix: `stripCodeFence` extracts a fenced block surrounded by prose
  instead of returning the text unchanged.
- fix: an empty Gemini / OpenAI reply names the finish reason in its
  error message (e.g. `MAX_TOKENS` when thinking used the whole budget).

## 0.2.1

- feat: `stripCodeFence` helper for stripping leading/trailing markdown code
  fences from model output, exported from the package barrel.

## 0.2.0

Initial release. `AiBroker` interface (`listModels`, `complete`, `chat`,
`stream`) with three implementations: `OpenAiBroker`, `AnthropicBroker`,
`GeminiBroker`. `AiBrokerRegistry` for runtime provider lookup.
`KeyResolver` (`EnvKeyResolver`, `MapKeyResolver`) for pluggable key
sourcing. Shared SSE decoder and retry-with-backoff helper.
