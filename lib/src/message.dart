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
  final double temperature;
  final int maxTokens;

  const ChatRequest({
    required this.system,
    required this.messages,
    this.temperature = 0.3,
    this.maxTokens = 2048,
  });

  /// Convenience for the single-shot case.
  factory ChatRequest.single({
    required String system,
    required String user,
    double temperature = 0.3,
    int maxTokens = 2048,
  }) =>
      ChatRequest(
        system: system,
        messages: [AiMessage.user(user)],
        temperature: temperature,
        maxTokens: maxTokens,
      );
}
