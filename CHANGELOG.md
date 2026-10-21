# Changelog

## 0.3.0

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
