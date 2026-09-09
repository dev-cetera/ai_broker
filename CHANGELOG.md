# Changelog

## 0.7.0

**Tool calling.** `AiStopReason.toolUse` has been in this package since 0.4.0
with nothing behind it: every provider supports tools, none of them was
reachable from here, and a model that wanted to call one came back as an empty
reply or a bare `AiBrokerException`. It now works on all three, from one
declaration, with the wire differences absorbed by the brokers.

- feat: `AiTool({name, description, inputSchema})` declares a tool once, in
  ordinary JSON Schema. `ChatRequest.tools` carries the list and
  `ChatRequest.toolChoice` (`auto` / `none` / `required`) says whether the
  model may, must, or must not call one. Both are null by default, so a
  request that predates this sends exactly the bytes it did in 0.6.1.
- feat: `AiCompletion.toolCalls` holds the `AiToolCall`s the model asked for —
  `id`, `name`, and **decoded** `arguments` — with `stopReason ==
  AiStopReason.toolUse` and `wantsTool` to say why the turn ended. Reachable
  from `chatDetailed` and from `streamDetailed`'s `completion`; `chat` and
  `stream` stay text-only and unchanged.
- feat: `AiMessage.assistantToolCalls(...)` and `AiMessage.toolResult({
  toolCallId, content, isError })` put the round trip back into the history for
  the next turn. All three providers reject a result whose call is not in the
  transcript above it, so both halves are needed.
- feat: streaming assembles tool calls as they arrive. Anthropic and OpenAI
  both dribble the arguments in as JSON fragments that parse only once
  concatenated — keyed by block index and by slot index respectively, because
  two calls interleave on the wire. Text deltas are untouched: a caller that
  ignores tools sees the same stream it always did.
- feat: the wire shapes, absorbed. Anthropic gets flat
  `tools: [{name, description, input_schema}]` and `tool_choice: {type: …}`
  where `required` is spelled `any`; OpenAI gets
  `tools: [{type: 'function', function: {…}}]` and a bare-string
  `tool_choice`; Gemini gets **one** `tools` entry holding every
  `functionDeclarations` member, with `parameters` translated by the existing
  `toGeminiSchema` because it takes the same OpenAPI-3 subset as
  `responseSchema`.
- feat: results go back in the shape each provider demands, which is where they
  diverge most. **Anthropic requires every result for a turn in a single user
  message** — a model that asked for three tools and got three separate
  messages back is a 400 — so consecutive `AiMessage.toolResult`s are coalesced
  into one. OpenAI wants the opposite: one `role: 'tool'` message per
  `tool_call_id`. Gemini coalesces like Anthropic but keys each
  `functionResponse` by function *name*.
- feat: `decodeToolArguments` is the shared parser, exported so a caller can
  see what it does. OpenAI sends `function.arguments` as a JSON **string**; it
  is parsed, never matched against — a value holding braces and escaped quotes
  breaks any substring approach. Anything that does not decode to an object (a
  stream cut mid-argument) yields an empty map and the call is still reported,
  because a call worth validating beats a call silently dropped.
- feat: Gemini's `functionCall` has no id, so `GeminiBroker` synthesises a
  stable one — `GeminiBroker.syntheticToolCallId(index, name)` — and recovers
  the name from it when feeding a result back without the calling turn in hand.
  Gemini also reports `finishReason: 'STOP'` on a turn that is nothing but
  function calls, so `stopReason` is normalised to `toolUse` from the calls
  themselves. Anthropic and OpenAI say so on the wire and are taken at their
  word — a tool call truncated by `max_tokens` still reads as truncated.
- feat: `OpenAiBroker.chatDetailed` / `streamDetailed` and
  `GeminiBroker.chatDetailed` are now real overrides rather than the
  zero-token defaults. They report `prompt_tokens` / `completion_tokens` /
  `cached_tokens` (`usageMetadata` on Gemini), the serving model, and a mapped
  stop reason — accounting the responses always carried and this package
  discarded on two of the three providers.
- **Behaviour change, narrow.** `chat` still returns a `String`, so a turn
  whose whole answer is a tool call still throws — there is nothing to return.
  The message now names the tool and points at `chatDetailed` instead of
  reporting a bare empty reply. Nothing about a request without `tools`
  changes; the payload is byte-for-byte what 0.6.1 sent.

## 0.6.1

- fix: the chat request timeout was raised to 120s in 0.4.0 for `AnthropicBroker`
  only. `GeminiBroker` and `OpenAiBroker` kept 30s, which is not enough for a
  reasoning model returning structured output over a large system prompt — a
  judge call measured 21.5s on a synthetic input and timed out on a real one,
  surfacing as a bare `TimeoutException` with nothing pointing at the cause.
  Both are now 120s. `GoogleTranslateBroker` stays at 30s; it does no reasoning.

## 0.6.0

**`ChatRequest.jsonSchema` was honoured by exactly one provider.** Anthropic
sent it as `output_config.format`; `GeminiBroker` and `OpenAiBroker` dropped it
without a word and answered in prose. A caller that asked for constrained JSON
and switched provider found out at the parse site, far from the cause — in
production, a prompt-improvement judge returned
`Here is the score for your input:\n\n**Item 1**...` instead of JSON and the
run was abandoned. Silently ignoring a constraint the caller asked for is the
worst of the available behaviours; all three brokers now honour it.

- feat: `GeminiBroker` sends `generationConfig.responseMimeType:
  'application/json'` plus a translated `responseSchema`. Gemini takes an
  **OpenAPI 3.0 subset**, not JSON Schema: forwarding the caller's schema
  unchanged is a 400 (`Unknown name "additionalProperties" at
  'generation_config.response_schema'`).
- feat: `OpenAiBroker` sends `response_format: {type: 'json_schema',
  json_schema: {name: 'response', strict: true, schema: …}}`.
- feat: `toGeminiSchema` / `toOpenAiStrictSchema` (new
  `lib/src/chat/json_schema.dart`) are the pure translation functions behind
  both, exported from the package so a caller can inspect exactly what a
  provider will be sent. The two providers want *opposite* things from the
  same schema, which is why this could not be a passthrough:
  Gemini rejects `additionalProperties`, OpenAI's strict mode **requires** it
  set to `false` on every object along with every property named in
  `required` — added where the caller left them out rather than assumed.
- feat: `toGeminiSchema` also drops the meta keywords (`$schema`, `$id`,
  `$defs`, `definitions`), inlines a local `$ref`, drops validation keywords
  the subset has no field for (`minLength`, `pattern`, `maximum`, …), and
  rewrites a nullable union — `type: ['string', 'null']` — as
  `type: 'string'` plus `nullable: true`.
- feat: when no safe translation exists — a recursive or unresolvable `$ref`,
  a genuine `['string', 'number']` union — `toGeminiSchema` returns null and
  the broker sends `responseMimeType` on its own. Unconstrained JSON is still
  JSON, and beats both prose and a rejected request.
- feat: `GeminiBroker.buildPayload` and `OpenAiBroker.buildPayload` are now
  `@visibleForTesting` rather than private, matching `AnthropicBroker`. Both
  streaming and non-streaming paths go through them, so structured output
  cannot diverge between `chat` and `stream`.
- **Behaviour change.** A request carrying `jsonSchema` now produces a
  different wire payload on Gemini and OpenAI than it did in 0.5.0, and the
  model's reply changes shape with it: JSON where prose used to come back.
  Callers that were compensating — stripping code fences, hunting for the
  first `{`, retrying on a parse failure — can drop that scaffolding, and
  should check any code that assumed prose. Anthropic is untouched; its
  payload is byte-for-byte what 0.5.0 sent.

## 0.5.0

**A streamed turn can now be billed.** `ChatBroker.stream` yields text and
throws the rest away, so anything that streams had no way to record token
usage or tell a refusal from a normal end. `streamDetailed` is the streaming
counterpart to 0.4.0's `chatDetailed`.

- feat: `ChatBroker.streamDetailed` returns a `StreamedCompletion` — a
  `Stream<String> deltas` that behaves exactly like `stream`, plus a
  `Future<AiCompletion> completion` that resolves when the stream ends with
  the usage, the serving model and the stop reason. Nothing is buffered: the
  text still arrives token by token.
- feat: `StreamedCompletion.fromDeltas` wraps any plain delta stream with a
  best-effort completion (accumulated text, zero tokens, `end_turn`). It backs
  the default `streamDetailed`, so every existing `ChatBroker` keeps working
  untouched.
- feat: `AnthropicBroker.streamDetailed` parses the accounting the SSE stream
  already carried and this package used to discard — `message_start` for the
  input and cache token counts and the model that actually served the turn,
  `message_delta` for the stop reason and the final output count. A
  mid-stream `refusal` now surfaces as `AiCompletion.isRefusal` instead of
  looking like a short reply.
- feat: `GeminiBroker.streamDetailed` reads `usageMetadata`
  (`promptTokenCount` / `candidatesTokenCount` / `cachedContentTokenCount`)
  and maps `finishReason` onto `AiStopReason` — every safety stop
  (`SAFETY`, `RECITATION`, `BLOCKLIST`, `PROHIBITED_CONTENT`, …) reads as a
  refusal, `MAX_TOKENS` as truncation.
- fix: cancelling a streamed turn mid-reply used to hang the consumer's own
  `subscription.cancel()` when no further bytes happened to arrive. Both
  streaming brokers now park on a yield point, so a cancel is acknowledged
  immediately — and `completion` settles with the part that did arrive.
- **Note for implementors.** `ChatBroker` gained a member. Subclasses
  (`extends ChatBroker`) inherit the default and need no change; classes that
  `implements ChatBroker` — hand-written fakes, mostly — must add a
  `streamDetailed`, which `StreamedCompletion.fromDeltas` makes a one-liner.

## 0.4.0

**Breaking, and it fixes a hard outage.** `ChatRequest.temperature` is now
`double?` and defaults to **null, meaning the field is not sent**. Every
current Claude model — Opus 5, Sonnet 5, and the whole 4.6+ family — rejects
`temperature` and `top_p` with a 400, so the previous unconditional
`temperature: 0.3` made this package unable to call any of them. Callers that
never set a temperature are fixed by upgrading; callers that pass one
explicitly keep the old behaviour and should drop it unless they target an
older model or OpenAI/Gemini.

- feat: `AiEffort` (`low` … `max`) — the modern replacement for the
  temperature knob. Sent as `output_config.effort`.
- feat: `ChatRequest.jsonSchema` constrains a reply to a JSON Schema via
  `output_config.format`. Removes the need for assistant prefill (also
  rejected by current models), code-fence stripping, and retry-on-parse loops.
- feat: `ChatRequest.cacheSystem` marks the system prompt as a cacheable
  prefix. Worth it whenever the same system text repeats across calls.
- feat: `ChatBroker.chatDetailed` returns an `AiCompletion` with the text plus
  token accounting (`inputTokens`, `outputTokens`, `cacheReadInputTokens`,
  `cacheCreationInputTokens`), the serving `model`, and an `AiStopReason`.
  It has a default implementation that delegates to `chat`, so existing
  `ChatBroker` implementations keep compiling.
- feat: `AiStopReason`, including `refusal`. A refusal arrives as an HTTP 200
  with empty content; `chatDetailed` reports it as a completion instead of
  throwing, so a chat UI can show a fallback and a scoring loop can record a
  skip.
- feat: `AnthropicBroker.baseUrl`, settable per instance or via the
  `ANTHROPIC_BASE_URL` environment variable, for proxies, gateways and local
  test doubles.
- feat: `AnthropicBroker.buildPayload` is visible for testing, so request
  shape can be asserted without a network call.
- fix: the Anthropic request timeout was 30s, which truncated long
  structured-output calls. Now 120s.
- docs: `example/modern_claude_example.dart` demonstrates the correct shape.

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
