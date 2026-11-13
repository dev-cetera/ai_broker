[![pub](https://img.shields.io/pub/v/ai_broker.svg)](https://pub.dev/packages/ai_broker)
[![tag](https://img.shields.io/badge/Tag-v0.8.0-purple?logo=github)](https://github.com/dev-cetera/ai_broker/tree/v0.8.0)
[![instagram](https://img.shields.io/badge/Instagram-E4405F?logo=instagram&logoColor=white)](https://www.instagram.com/dev_cetera/)
[![license](https://img.shields.io/badge/License-MIT-blue.svg)](https://raw.githubusercontent.com/dev-cetera/ai_broker/main/LICENSE)

---

<!-- BEGIN _README_CONTENT -->

Provider-agnostic Dart abstraction over Claude, OpenAI, DeepSeek, Gemini and
any OpenAI-compatible API, **plus a RAG layer and a ready-to-use CLI** for ingesting documents, searching them,
and asking questions grounded in the results.

One library, two ways to use it:

1. **As a library** — wire `OpenAiBroker` / `AnthropicBroker` / `GeminiBroker`
   / `DeepSeekBroker` / `OpenAiCompatibleBroker` into your app (Dart or
   Flutter, including the web) and call `complete`, `chat`, `stream`, or `embed` through a
   single interface. Optionally use the RAG primitives (`SentenceWindowChunker`,
   `Embedder`, `CorpusStore`) to build your own retrieval-augmented features.
2. **As a CLI** — `dart pub global activate ai_broker` and use `ai_broker`
   (alias `aib`) to ingest text into a local vector store, search it, and
   ask a chat model grounded questions against it. See
   [`doc/cli.md`](doc/cli.md) for the full CLI reference.

## Why

Most apps that touch more than one LLM provider end up with three
near-duplicate HTTP wrappers. `ai_broker` collapses them behind one
interface so a feature written against `AiBroker` runs against any
provider — and adding the next provider is one file in
`lib/src/brokers/`, not three.

The RAG layer is the same principle applied a level up: chunk, embed, store,
retrieve, ground. One pipeline that works against any of the supported embed
providers, with the chat broker chosen independently.

## Broker interfaces (capability-split, 0.4.0+)

Each capability is its own interface. Providers implement only the ones
their service actually supports — no "throws UnsupportedError" stubs.

```dart
abstract class AiBroker {                       // base: id, label, listModels
  String get id;                                // 'openai' | 'anthropic' | 'gemini'
  String get label;
  Future<List<String>> listModels(String apiKey);
}

abstract class ChatBroker implements AiBroker {
  Future<String> complete({ ... });                                    // single-shot
  Future<String> chat({ ... ChatRequest request });                    // multi-turn
  Future<AiCompletion> completeWithMeta({ ... });                      // + finish reason, token counts
  Future<AiCompletion> chatWithMeta({ ... ChatRequest request });      // the one call every chat broker implements
  Stream<String> stream({ ... ChatRequest request });                  // token-by-token
  Future<AiCompletion> chatWithMeta({ ... ChatRequest request });      // + usage / stop reason
  StreamedCompletion streamWithMeta({ ... ChatRequest request });      // streamed, + usage
}

abstract class EmbedBroker implements AiBroker {
  Future<List<List<double>>> embed({ ... List<String> inputs });
}
```

| Provider | Implements |
|----------|-----------|
| `OpenAiBroker` | `ChatBroker` + `EmbedBroker` + `KeyCheckBroker` |
| `AnthropicBroker` | `ChatBroker` + `KeyCheckBroker` (no embed — Anthropic has no first-party embeddings) |
| `GeminiBroker` | `ChatBroker` + `EmbedBroker` + `KeyCheckBroker` |
| `DeepSeekBroker` | `ChatBroker` + `KeyCheckBroker` |
| `OpenAiCompatibleBroker` | `ChatBroker` + `KeyCheckBroker` — any OpenAI-style API |
| `GoogleTranslateBroker` | `TranslateBroker` + `KeyCheckBroker` |

`completeWithMeta` / `chatWithMeta` return an `AiCompletion`: the text,
the provider's raw finish reason (`'STOP'`, `'end_turn'`, `'length'`, …),
that reason mapped onto `AiFinishReason` (`null` when unmapped), and the
input / output / thinking token counts. Check
`finishReason == AiFinishReason.maxTokens` to tell a reply cut off at the
token limit from a complete one.

Every non-streaming call retries 429 / 500 / 502 / 503 / 504 / 529 and
transient network errors with exponential backoff, honouring
`Retry-After` (capped at 60 s). A timed-out request is not retried — the
provider may still be generating (and billing) it.

Wire once via `AiBrokerRegistry`, look up by id thereafter. For
capability-typed lookups use `lookupAs<T>` — returns `null` when the
broker doesn't implement the requested capability:

```dart
final embed = AiBrokerRegistry.instance.lookupAs<EmbedBroker>('anthropic');
// → null  (Anthropic doesn't implement EmbedBroker)

final embed = AiBrokerRegistry.instance.lookupAs<EmbedBroker>('openai');
// → OpenAiBroker (typed as EmbedBroker)
```

> **Breaking change vs 0.3.x.** `chat` / `stream` / `complete` (and
> 0.3.0's `chatWithMeta` / `completeWithMeta`) were on `AiBroker`
> directly. Code like `broker.chat(...)` against a
> variable typed as `AiBroker` no longer compiles — either declare the
> variable as `ChatBroker` / `EmbedBroker`, cast at the call site, or
> use `lookupAs<ChatBroker>('id')` from the registry.

## Library quick start — chat

```dart
import 'package:ai_broker/ai_broker.dart';

void main() async {
  AiBrokerRegistry.instance
    ..register(OpenAiBroker())
    ..register(AnthropicBroker())
    ..register(GeminiBroker());

  final broker = AiBrokerRegistry.instance.lookupAs<ChatBroker>('anthropic')!;
  final keys = EnvKeyResolver();                 // reads ANTHROPIC_API_KEY
  final apiKey = await keys.require(broker.id);

  final answer = await broker.complete(
    apiKey: apiKey,
    model: 'claude-sonnet-4-6',
    system: 'You answer concisely.',
    user: 'Capital of France?',
  );
  print(answer);

  // Streaming:
  final stream = broker.stream(
    apiKey: apiKey,
    model: 'claude-sonnet-4-6',
    request: const ChatRequest(
      system: 'You write short prose.',
      messages: [AiMessage.user('Describe an ocean sunset.')],
    ),
  );
  await for (final chunk in stream) {
    stdout.write(chunk);
  }

  // Streaming, with the accounting the stream already carries. Same text,
  // same timing — plus what the turn cost and why it ended.
  final turn = broker.streamWithMeta(
    apiKey: apiKey,
    model: 'claude-sonnet-4-6',
    request: const ChatRequest(
      system: 'You write short prose.',
      messages: [AiMessage.user('Describe an ocean sunset.')],
    ),
  );
  await for (final delta in turn.deltas) {
    stdout.write(delta);
  }
  final done = await turn.completion;         // resolves when the stream ends
  if (done.isRefusal) stderr.writeln('the model declined');
  print('\n${done.inputTokens} in / ${done.outputTokens} out on ${done.model}');
}
```

## Structured output (0.8.0+)

Set `ChatRequest.jsonSchema` and the reply comes back as valid JSON by
construction — no code fences to strip, no brace-hunting, no
retry-on-parse loop. **Every chat broker honours it**, each in its own
dialect:

| Provider | Wire field |
|----------|-----------|
| `AnthropicBroker` | `output_config.format` — the schema verbatim |
| `OpenAiBroker` | `response_format` — `strict: true`, via `toOpenAiStrictSchema` |
| `GeminiBroker` | `generationConfig.responseMimeType` + `responseSchema`, via `toGeminiSchema` |
| `DeepSeekBroker` | `response_format: {type: 'json_object'}` plus the schema in the system prompt — DeepSeek has JSON mode only, so the shape is asked for, not enforced |

```dart
const schema = {
  'type': 'object',
  'additionalProperties': false,
  'required': ['verdict', 'reason'],
  'properties': {
    'verdict': {'type': 'string', 'enum': ['PASS', 'FAIL']},
    'reason': {'type': ['string', 'null']},
  },
};

final raw = await broker.chat(
  apiKey: apiKey,
  model: model,
  request: const ChatRequest(
    system: 'You score answers.',
    messages: [AiMessage.user('Is 2 + 2 = 5?')],
    jsonSchema: schema,
  ),
);
final scored = jsonDecode(raw) as Map<String, Object?>;   // safe on all three
```

Write it once as ordinary JSON Schema; the package reconciles the
providers, which disagree in *opposite* directions — Gemini 400s on
`additionalProperties`, OpenAI's strict mode requires it (and requires
every property to appear in `required`). The translations are pure
functions you can call yourself to see exactly what will be sent:

```dart
toGeminiSchema(schema);       // OpenAPI 3.0 subset, or null if inexpressible
toOpenAiStrictSchema(schema); // strict-mode JSON Schema
```

Portable subset: objects with `properties` / `required` /
`additionalProperties: false`, arrays with `items`, `enum` for closed string
sets, and `type: ['string', 'null']` for nullable fields. Value bounds
(`minLength`, `maximum`, `pattern`, …) are dropped on the way to Gemini —
state those in the prompt. A schema Gemini cannot express at all (a recursive
`$ref`, a `['string', 'number']` union) still yields JSON, just unconstrained.

## Tool calling (0.8.0+)

Declare tools once with `AiTool`; **every chat broker honours them**, in three
incompatible dialects:

| Provider | Declaration | Result goes back as |
|----------|-------------|---------------------|
| `AnthropicBroker` | `tools: [{name, description, input_schema}]` | `tool_result` blocks — **all of a turn's in one user message** |
| `OpenAiBroker` | `tools: [{type: 'function', function: {…}}]` | one `role: 'tool'` message per `tool_call_id` |
| `GeminiBroker` | one `tools: [{functionDeclarations: […]}]` entry, via `toGeminiSchema` | `functionResponse` parts, keyed by function *name* |

The package never runs a tool. It reports what the model asked for; you
execute it and hand the answer back on the next turn:

```dart
const tools = [
  AiTool(
    name: 'get_weather',
    description: 'Look up the current weather for a city.',
    inputSchema: {
      'type': 'object',
      'properties': {'city': {'type': 'string'}},
      'required': ['city'],
    },
  ),
];

final messages = <AiMessage>[AiMessage.user('Weather in Canberra?')];

// Tool calls live on the *detailed* results — `chat` and `stream` are
// text-only, and a turn that is nothing but a call has no text to return.
var turn = await broker.chatWithMeta(
  apiKey: apiKey,
  model: model,
  request: ChatRequest(system: '', messages: messages, tools: tools),
);

while (turn.wantsTool) {
  // Replay the assistant turn — every provider rejects a result whose call
  // is not in the transcript above it.
  messages
    ..add(AiMessage.assistantToolCalls(turn.toolCalls, content: turn.text))
    ..addAll([
      for (final call in turn.toolCalls)
        AiMessage.toolResult(
          toolCallId: call.id,
          content: await runTool(call.name, call.arguments), // yours
        ),
    ]);
  turn = await broker.chatWithMeta(
    apiKey: apiKey,
    model: model,
    request: ChatRequest(system: '', messages: messages, tools: tools),
  );
}

print(turn.text);
```

`AiToolCall.arguments` is always a decoded `Map` — OpenAI sends it as a JSON
*string* and `decodeToolArguments` parses it, so nothing downstream is tempted
to match on the raw text. `ChatRequest.toolChoice` (`auto` / `none` /
`required`) forces the issue when you need it; `required` is sent as
Anthropic's `any` and Gemini's `ANY`.

Streaming works the same way: `streamWithMeta(...).deltas` keeps yielding text
exactly as before, and the completed calls land on `.completion` once the
arguments — which arrive as unparseable JSON fragments on Anthropic and OpenAI
— have been reassembled.

## OpenAI-compatible providers and DeepSeek (0.8.0+)

`OpenAiCompatibleBroker` talks to anything that serves the OpenAI Chat
Completions API: OpenRouter, Mistral, Groq, xAI, Together, or a local Ollama,
LM Studio or vLLM server.

```dart
final groq = OpenAiCompatibleBroker(
  id: 'groq',
  label: 'Groq',
  baseUrl: 'https://api.groq.com/openai/v1',
);
final ollama = OpenAiCompatibleBroker(
  id: 'ollama',
  label: 'Ollama',
  baseUrl: 'http://localhost:11434/v1',
);
```

The knobs are the ways these APIs differ: `maxTokensField`
(`max_tokens` by default; OpenAI uses `max_completion_tokens`),
`supportsJsonSchema`, `streamUsage`, `modelFilter` for `listModels`, and
`extraHeaders` (OpenRouter's `HTTP-Referer`, say). `OpenAiBroker` and
`DeepSeekBroker` are presets of it.

`ChatRequest.effort` becomes `reasoning_effort` on these APIs (and
`output_config.effort` on Anthropic). `temperature` is sent only when you set
it: current Claude models and OpenAI reasoning models reject it.

## Bring-your-own-key apps (0.8.0+)

For an app where each user pastes their own key:

```dart
final broker = AiBrokerRegistry.instance.lookupAs<KeyCheckBroker>('deepseek')!;
final check = await broker.checkKey(pastedKey);
switch (check.status) {
  case AiKeyStatus.valid:       // save it
  case AiKeyStatus.invalid:     // "That key was rejected"
  case AiKeyStatus.unreachable: // "Couldn't reach DeepSeek, try again"
  case AiKeyStatus.error:       // show check.message (e.g. no credit left)
}
```

`checkKey` is one metadata request (usually the model list), never a
completion, so it costs nothing. `listModels` can't make this distinction: it
returns `[]` for a bad key, a dead network and an empty catalogue alike.

**On the web**, a browser only lets the request through if the provider allows
CORS. Anthropic requires an explicit opt-in:
`AnthropicBroker(browserAccess: true)` sends
`anthropic-dangerous-direct-browser-access: true`. Use it only with the
user's own key — anything in the browser can be read from its developer
tools. Whether other providers accept browser requests is up to them; check
before you rely on it, or route through your own proxy (`baseUrl`).

## Cancelling a request (0.9.0+)

Every request method on `ChatBroker` takes an optional `abortTrigger`. Complete
it and the HTTP request is aborted — the connection is closed, so the provider
stops generating (and billing) — and the call throws `AiAbortedException`:

```dart
final stop = Completer<void>();
stopButton.onPressed = stop.complete;

try {
  final answer = await broker.chat(
    apiKey: apiKey,
    model: 'claude-sonnet-4-6',
    request: request,
    abortTrigger: stop.future,
  );
  show(answer);
} on AiAbortedException {
  // The user stopped it; nothing to report.
} on AiBrokerException catch (e) {
  showError(e.message);
}
```

A stream (`stream`, or `streamWithMeta().deltas`) ends with
`AiAbortedException` as its error, and `streamWithMeta().completion` fails with
it too. A trigger that has already completed throws before anything is sent,
and an aborted request is never retried — a pending backoff ends at once.
`AiAbortedException` is an `AiBrokerException`, so catch it first.

## Library quick start — RAG

```dart
import 'dart:io';
import 'package:ai_broker/ai_broker.dart';

void main() async {
  final keys = EnvKeyResolver();

  // 1. Embed broker — needs to support embed(). OpenAI or Gemini.
  final embedBroker = OpenAiBroker();
  final embedder = Embedder(
    broker: embedBroker,
    apiKey: await keys.require(embedBroker.id),
    model: OpenAiBroker.defaultEmbedModel,        // 'text-embedding-3-small'
  );

  // 2. Open / create a local SQLite-backed store.
  final store = CorpusStore.openOrCreate('corpus.db');

  // 3. Ingest a document.
  final text = await File('handbook.md').readAsString();
  final chunks = const SentenceWindowChunker().chunk(text, sourcePath: 'handbook.md');
  final vectors = await embedder.embedAll(chunks.map((c) => c.text).toList());

  store.upsertCollection(
    name: 'handbook',
    embedBroker: embedBroker.id,
    embedModel: embedder.model,
    dim: vectors.first.length,
  );
  store.addDocument(
    collection: 'handbook',
    sourcePath: 'handbook.md',
    contentHash: 'h1',
    chunks: chunks,
    vectors: vectors,
  );

  // 4. Search.
  final queryVec = await embedder.embedOne('how do I rotate the API key?');
  final hits = store.search(collection: 'handbook', queryVector: queryVec, topK: 5);
  for (final h in hits) {
    print('${h.chunk.sourcePath}#${h.chunk.ord}  ${h.score.toStringAsFixed(3)}');
  }
  store.close();
}
```

## CLI quick start

```sh
# Install (puts `ai_broker` and `aib` on PATH).
dart pub global activate ai_broker

# Put your keys in a .env file (gitignored). The CLI auto-loads ./.env.
echo "OPENAI_API_KEY=sk-..."     >> .env
echo "ANTHROPIC_API_KEY=sk-ant-..." >> .env

# 1. Ingest some files into a local collection.
ai_broker ingest --collection handbook --ext .md,.txt docs/

# 2. Search them (snippets only, no LLM).
ai_broker search --collection handbook "key rotation"

# 3. Ask a question — retrieval + grounded answer (Anthropic by default).
ai_broker ask --collection handbook "How do I rotate the API key?"

# 4. Translate — Google Cloud Translation by default; --broker openai|anthropic|gemini|deepseek
#    routes through an LLM with domain / tone / glossary hints.
ai_broker translate --to fr "the catalyst is unstable"
ai_broker translate --to fr --broker anthropic --domain chemistry --tone formal \
  --glossary "catalyst=catalyseur" "the catalyst is unstable"
```

Full reference: [`doc/cli.md`](doc/cli.md).

## Key resolution

API keys arrive per call. The library ships four `KeyResolver`s and a
helper that chains them for the CLI:

| Resolver | Use when |
| --- | --- |
| `EnvKeyResolver` | Reads `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `DEEPSEEK_API_KEY` (overridable). Native only. Pass `lookup:` to read them from somewhere else, e.g. a desktop app parsing the user's shell profile. |
| `MapKeyResolver` | Tests, or apps that already hold keys in a map. |
| `FileKeyResolver.fromFile(path)` | Parses `.env`-style files (`KEY=value`) or loose `claude: …` / `openai key: …` lines. |
| `ChainedKeyResolver([…])` | Tries each layer in order, returns the first non-empty hit. |
| (your own) | Flutter apps using secure storage — implement `KeyResolver` against your store. |

The CLI uses `ChainedKeyResolver([direct flags, --env-file or ./.env, env vars])`
by default. Library users in Flutter apps with secure storage can skip
`KeyResolver` entirely and pass `apiKey:` directly.

## What it doesn't do

- **No safety gate.** Prompt sanitisation, output filtering, content
  moderation — call-site concern.
- **No tool execution.** Tool *calling* is supported (0.8.0+) — declaring
  tools, reading back what the model asked for, feeding results in — but
  running the tool is yours. No sandbox, no dispatch table, no retry loop.
- **No reranking** in the RAG layer — cosine top-K only. Add a cross-encoder
  or Cohere Rerank at the call site if quality demands it.
- **No Flutter widgets.** Pure Dart. Build pickers / chat UIs / settings
  dialogs on top in the consuming app.
- **No web support for the RAG layer.** `CorpusStore` depends on native
  `package:sqlite3`. The chat / embed / translate / key-check APIs are pure
  Dart and work on the web (dart2js and dart2wasm); the storage layer is
  native-only today.

## Run the example

```sh
dart pub get
ANTHROPIC_API_KEY=sk-... dart run example/example.dart anthropic
OPENAI_API_KEY=sk-...    dart run example/example.dart openai gpt-4o-mini
GEMINI_API_KEY=...       dart run example/example.dart gemini gemini-2.5-flash
```

<!-- END _README_CONTENT -->

---

🔍 For more information, refer to the [API reference](https://pub.dev/documentation/ai_broker/).

---

## 💬 Contributing and Discussions

This is an open-source project, and we warmly welcome contributions from everyone, regardless of experience level. Whether you're a seasoned developer or just starting out, contributing to this project is a fantastic way to learn, share your knowledge, and make a meaningful impact on the community.

### ☝️ Ways you can contribute

- **Raise a ticket:** Open an issue on the [GitHub repository](https://github.com/dev-cetera/ai_broker/issues) for questions, bugs and feature requests.
- **Get in touch:** Email [hello@robertsolves.com.au](mailto:hello@robertsolves.com.au) if you would like to contribute or collaborate.
- **Share your ideas:** Every perspective matters, and your ideas can spark innovation.
- **Help others:** Engage with other users by offering advice, solutions, or troubleshooting assistance.
- **Report bugs:** Help us identify and fix issues to make the project more robust.
- **Suggest improvements or new features:** Your ideas can help shape the future of the project.
- **Help clarify documentation:** Good documentation is key to accessibility. You can make it easier for others to get started by improving or expanding our documentation.
- **Write articles:** Share your knowledge by writing tutorials, guides, or blog posts about your experiences with the project. It's a great way to contribute and help others learn.

No matter how you choose to contribute, your involvement is greatly appreciated and valued!

## 👤 Author & Contact

- Website: [robertsolves.com.au](https://robertsolves.com.au)
- Organization: [dev-cetera.com](https://dev-cetera.com)
- Email: [robert@dev-cetera.com](mailto:robert@dev-cetera.com) or [hello@robertsolves.com.au](mailto:hello@robertsolves.com.au)

## LICENSE

This project is released under the [MIT License](https://raw.githubusercontent.com/dev-cetera/ai_broker/main/LICENSE). See [LICENSE](https://raw.githubusercontent.com/dev-cetera/ai_broker/main/LICENSE) for more information.
