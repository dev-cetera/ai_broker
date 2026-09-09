[![pub](https://img.shields.io/pub/v/ai_broker.svg)](https://pub.dev/packages/ai_broker)
[![tag](https://img.shields.io/badge/Tag-v0.2.2-purple?logo=github)](https://github.com/dev-cetera/ai_broker/tree/v0.2.2)
[![buymeacoffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-FFDD00?logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/dev_cetera)
[![sponsor](https://img.shields.io/badge/Sponsor-grey?logo=github-sponsors&logoColor=pink)](https://github.com/sponsors/dev-cetera)
[![patreon](https://img.shields.io/badge/Patreon-grey?logo=patreon)](https://www.patreon.com/robelator)
[![discord](https://img.shields.io/badge/Discord-5865F2?logo=discord&logoColor=white)](https://discord.gg/gEQ8y2nfyX)
[![instagram](https://img.shields.io/badge/Instagram-E4405F?logo=instagram&logoColor=white)](https://www.instagram.com/dev_cetera/)
[![license](https://img.shields.io/badge/License-MIT-blue.svg)](https://raw.githubusercontent.com/dev-cetera/ai_broker/main/LICENSE)

---

<!-- BEGIN _README_CONTENT -->

Provider-agnostic Dart abstraction over Claude, OpenAI, and Gemini, **plus a
RAG layer and a ready-to-use CLI** for ingesting documents, searching them,
and asking questions grounded in the results.

One library, two ways to use it:

1. **As a library** — wire `OpenAiBroker` / `AnthropicBroker` / `GeminiBroker`
   into your app and call `complete`, `chat`, `stream`, or `embed` through a
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

## Broker interfaces (capability-split, 0.3.0+)

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
  Stream<String> stream({ ... ChatRequest request });                  // token-by-token
  Future<AiCompletion> chatDetailed({ ... ChatRequest request });      // + usage / stop reason
  StreamedCompletion streamDetailed({ ... ChatRequest request });      // streamed, + usage
}

abstract class EmbedBroker implements AiBroker {
  Future<List<List<double>>> embed({ ... List<String> inputs });
}
```

| Provider | Implements |
|----------|-----------|
| `OpenAiBroker` | `ChatBroker` + `EmbedBroker` |
| `AnthropicBroker` | `ChatBroker` (no embed — Anthropic has no first-party embeddings) |
| `GeminiBroker` | `ChatBroker` + `EmbedBroker` |

Wire once via `AiBrokerRegistry`, look up by id thereafter. For
capability-typed lookups use `lookupAs<T>` — returns `null` when the
broker doesn't implement the requested capability:

```dart
final embed = AiBrokerRegistry.instance.lookupAs<EmbedBroker>('anthropic');
// → null  (Anthropic doesn't implement EmbedBroker)

final embed = AiBrokerRegistry.instance.lookupAs<EmbedBroker>('openai');
// → OpenAiBroker (typed as EmbedBroker)
```

> **Breaking change vs 0.2.x.** `chat` / `stream` / `complete` / `embed`
> were on `AiBroker` directly. Code like `broker.chat(...)` against a
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
  final turn = broker.streamDetailed(
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

## Structured output (0.6.0+)

Set `ChatRequest.jsonSchema` and the reply comes back as valid JSON by
construction — no code fences to strip, no brace-hunting, no
retry-on-parse loop. **Every chat broker honours it**, each in its own
dialect:

| Provider | Wire field |
|----------|-----------|
| `AnthropicBroker` | `output_config.format` — the schema verbatim |
| `OpenAiBroker` | `response_format` — `strict: true`, via `toOpenAiStrictSchema` |
| `GeminiBroker` | `generationConfig.responseMimeType` + `responseSchema`, via `toGeminiSchema` |

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

# 4. Translate — Google Cloud Translation by default; --broker openai|anthropic|gemini
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
| `EnvKeyResolver` | Reads `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` (overridable). |
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
- **No tools / function calling** yet.
- **No reranking** in the RAG layer — cosine top-K only. Add a cross-encoder
  or Cohere Rerank at the call site if quality demands it.
- **No Flutter widgets.** Pure Dart. Build pickers / chat UIs / settings
  dialogs on top in the consuming app.
- **No web support for the RAG layer.** `CorpusStore` depends on native
  `package:sqlite3`. The chat / embed APIs (`AiBroker`, `Embedder`,
  `SentenceWindowChunker`) are pure Dart and work on web; the storage layer
  is native-only today.

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

- **Find us on Discord:** Feel free to ask questions and engage with the community here: https://discord.gg/gEQ8y2nfyX.
- **Share your ideas:** Every perspective matters, and your ideas can spark innovation.
- **Help others:** Engage with other users by offering advice, solutions, or troubleshooting assistance.
- **Report bugs:** Help us identify and fix issues to make the project more robust.
- **Suggest improvements or new features:** Your ideas can help shape the future of the project.
- **Help clarify documentation:** Good documentation is key to accessibility. You can make it easier for others to get started by improving or expanding our documentation.
- **Write articles:** Share your knowledge by writing tutorials, guides, or blog posts about your experiences with the project. It's a great way to contribute and help others learn.

No matter how you choose to contribute, your involvement is greatly appreciated and valued!

### ☕ We drink a lot of coffee...

If you're enjoying this package and find it valuable, consider showing your appreciation with a small donation. Every bit helps in supporting future development. You can donate here: https://www.buymeacoffee.com/dev_cetera

<a href="https://www.buymeacoffee.com/dev_cetera" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/default-orange.png" height="40"></a>

## LICENSE

This project is released under the [MIT License](https://raw.githubusercontent.com/dev-cetera/ai_broker/main/LICENSE). See [LICENSE](https://raw.githubusercontent.com/dev-cetera/ai_broker/main/LICENSE) for more information.
