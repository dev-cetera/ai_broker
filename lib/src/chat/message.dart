//.title
// ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
//
// Copyright © dev-cetera.com & contributors.
//
// The use of this source code is governed by an MIT-style license described in
// the LICENSE file located in this project's root directory.
//
// See: https://opensource.org/license/mit
//
// ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
//.title~

import '/_common.dart';

/// Who authored a message in a chat. `system` lives on
/// [ChatRequest.system], not here — every provider treats system
/// instructions specially (Anthropic puts them at top-level; Gemini
/// uses `systemInstruction`; OpenAI uses a `role:system` message). We
/// only model the back-and-forth.
enum AiRole {
  user,
  assistant,
}

@immutable
class AiMessage {
  final AiRole role;
  final String content;

  const AiMessage(this.role, this.content);

  const AiMessage.user(this.content) : role = AiRole.user;
  const AiMessage.assistant(this.content) : role = AiRole.assistant;

  String get roleName => role == AiRole.user ? 'user' : 'assistant';

  @override
  String toString() => '${role.name}: $content';
}

/// What every broker call boils down to. [system] is the persistent
/// instruction; [messages] is the turn history (oldest first). Both
/// `complete*` and `chat*` build the same wire payload — `complete*`
/// is just `chat*` with one user message.
@immutable
class ChatRequest {
  final String system;
  final List<AiMessage> messages;

  /// Sampling temperature. **Null means "do not send it at all"**, which is
  /// the default and the only thing current Claude models accept — Opus 5,
  /// Sonnet 5 and the 4.6+ family reject `temperature` and `top_p` with a
  /// 400. Set it only when targeting an older model or a provider that still
  /// honours it (OpenAI and Gemini do).
  final double? temperature;

  final int maxTokens;

  /// How hard the model should work. The modern replacement for
  /// [temperature]; see [AiEffort]. Ignored by providers without an
  /// equivalent knob.
  final AiEffort? effort;

  /// When set, the reply is constrained to this JSON Schema and comes back
  /// as valid JSON by construction — no code fences to strip, no
  /// retry-on-parse loop. Every object in the schema needs
  /// `additionalProperties: false` and a `required` list.
  final Map<String, Object?>? jsonSchema;

  /// Mark the system prompt as a cacheable prefix. Worth it whenever the
  /// same system text is reused across calls — a long knowledge base sent
  /// on every turn, or a judge re-scoring the same prompt each round.
  final bool cacheSystem;

  const ChatRequest({
    required this.system,
    required this.messages,
    this.temperature,
    this.maxTokens = 2048,
    this.effort,
    this.jsonSchema,
    this.cacheSystem = false,
  })  : assert(
          maxTokens > 0,
          'ChatRequest.maxTokens must be positive.',
        ),
        assert(
          temperature == null || (temperature >= 0.0 && temperature <= 2.0),
          'ChatRequest.temperature must be in [0.0, 2.0] when set.',
        );

  /// Convenience for the single-shot case.
  factory ChatRequest.single({
    required String system,
    required String user,
    double? temperature,
    int maxTokens = 2048,
    AiEffort? effort,
    Map<String, Object?>? jsonSchema,
    bool cacheSystem = false,
  }) =>
      ChatRequest(
        system: system,
        messages: [AiMessage.user(user)],
        temperature: temperature,
        maxTokens: maxTokens,
        effort: effort,
        jsonSchema: jsonSchema,
        cacheSystem: cacheSystem,
      );
}
