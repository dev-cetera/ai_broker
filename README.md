[![pub](https://img.shields.io/pub/v/ai_broker.svg)](https://pub.dev/packages/ai_broker)
[![tag](https://img.shields.io/badge/Tag-v0.2.0-purple?logo=github)](https://github.com/dev-cetera/ai_broker/tree/v0.2.0)
[![buymeacoffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-FFDD00?logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/dev_cetera)
[![sponsor](https://img.shields.io/badge/Sponsor-grey?logo=github-sponsors&logoColor=pink)](https://github.com/sponsors/dev-cetera)
[![patreon](https://img.shields.io/badge/Patreon-grey?logo=patreon)](https://www.patreon.com/robelator)
[![discord](https://img.shields.io/badge/Discord-5865F2?logo=discord&logoColor=white)](https://discord.gg/gEQ8y2nfyX)
[![instagram](https://img.shields.io/badge/Instagram-E4405F?logo=instagram&logoColor=white)](https://www.instagram.com/dev_cetera/)
[![license](https://img.shields.io/badge/License-MIT-blue.svg)](https://raw.githubusercontent.com/dev-cetera/ai_broker/main/LICENSE)

---

<!-- BEGIN _README_CONTENT -->

# ai_broker

Provider-agnostic Dart abstraction over Claude, OpenAI, and Gemini. One
interface for listing models, single-shot completions, multi-turn chat,
and token streaming.

Internal to the `dev_cetera` workspace — not on pub.dev.

## Why

Several apps in this workspace (`powerdb`, `chitbot`, `heylang`,
`compledo`) each grew their own AI provider wrappers. `ai_broker`
consolidates them so a feature implemented against `AiBroker` can run
against any provider — and so adding the next provider is one file in
`lib/src/brokers/`, not three.

## Shape

```dart
abstract class AiBroker {
  String get id;                                        // 'openai' | 'anthropic' | 'gemini'
  String get label;
  Future<List<String>> listModels(String apiKey);
  Future<String> complete({ ... });                     // single-shot
  Future<String> chat({ ... ChatRequest request });     // multi-turn
  Stream<String> stream({ ... ChatRequest request });   // token-by-token
}
```

Concrete brokers: `OpenAiBroker`, `AnthropicBroker`, `GeminiBroker`.
Wire once via `AiBrokerRegistry`, look up by id thereafter.

## Quick start

```dart
import 'package:ai_broker/ai_broker.dart';

void main() async {
  AiBrokerRegistry.instance
    ..register(OpenAiBroker())
    ..register(AnthropicBroker())
    ..register(GeminiBroker());

  final broker = AiBrokerRegistry.instance.lookup('anthropic')!;
  final keys = EnvKeyResolver();                 // reads ANTHROPIC_API_KEY
  final apiKey = await keys.require(broker.id);

  final answer = await broker.complete(
    apiKey: apiKey,
    model: 'claude-opus-4-7',
    system: 'You answer concisely.',
    user: 'Capital of France?',
  );
  print(answer);

  // Streaming:
  final stream = broker.stream(
    apiKey: apiKey,
    model: 'claude-opus-4-7',
    request: const ChatRequest(
      system: 'You write short prose.',
      messages: [AiMessage.user('Describe an ocean sunset.')],
    ),
  );
  await for (final chunk in stream) {
    stdout.write(chunk);
  }
}
```

## Key resolution

API keys arrive per call. Pick a [`KeyResolver`](lib/src/key_resolver.dart):

| Resolver | Use when |
| --- | --- |
| `EnvKeyResolver` | CLI / backend code. Reads `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` (overridable). |
| `MapKeyResolver` | Tests, or apps that already hold keys in a map. |
| (your own) | Flutter apps using secure storage — implement `KeyResolver` against your store. |

For Flutter apps that already manage settings + secure storage (like
`powerdb`), you can skip `KeyResolver` and pass `apiKey:` directly.

## What it doesn't do

- **No safety gate.** `powerdb` has a SQL read-only enforcer; that
  belongs at the call site, not in this package.
- **No persistence.** Settings, key storage, model selection — caller's
  problem.
- **No tools / function calling.** Add when a consumer actually needs
  it; today nothing in the workspace does.
- **No Flutter widgets.** Pure Dart. Build pickers / settings dialogs
  on top in the consuming app.

## Files

```
lib/
  ai_broker.dart                    # public entry — re-exports src
  _common.dart                      # internal umbrella (dart:* + http + meta)
  src/
    broker.dart                     # AiBroker, AiBrokerRegistry, AiBrokerException
    message.dart                    # AiMessage, AiRole, ChatRequest
    key_resolver.dart               # KeyResolver, EnvKeyResolver, MapKeyResolver
    retry.dart                      # exponential backoff for 429/503/529
    sse.dart                        # shared SSE decoder for streaming
    brokers/
      openai_broker.dart
      anthropic_broker.dart
      gemini_broker.dart
```

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
