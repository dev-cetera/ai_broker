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

  /// The tool calls this assistant turn asked for. Empty on every message
  /// that is not a tool-use turn, which is all of them until a caller starts
  /// replaying [AiCompletion.toolCalls] into the history.
  ///
  /// Replaying matters: all three providers reject a tool result whose call
  /// is not in the transcript above it. Append
  /// `AiMessage.assistantToolCalls(done.toolCalls, content: done.text)`
  /// before the results.
  final List<AiToolCall> toolCalls;

  /// The [AiToolCall.id] this message answers, on a message built by
  /// [AiMessage.toolResult]. Null on every other message.
  final String? toolCallId;

  /// Whether [content] is a failure report rather than a result. Anthropic
  /// has a field for it (`is_error`); the other two do not, so it only
  /// changes how the text is framed there.
  final bool isError;

  const AiMessage(this.role, this.content)
      : toolCalls = const [],
        toolCallId = null,
        isError = false;

  const AiMessage.user(this.content)
      : role = AiRole.user,
        toolCalls = const [],
        toolCallId = null,
        isError = false;

  const AiMessage.assistant(this.content)
      : role = AiRole.assistant,
        toolCalls = const [],
        toolCallId = null,
        isError = false;

  /// The assistant turn that asked for tools, replayed into the history.
  ///
  /// [content] is whatever text came alongside the calls — usually empty,
  /// sometimes a sentence of narration. Pass [AiCompletion.text] straight
  /// through; an empty string is dropped from the payload rather than sent as
  /// an empty block.
  const AiMessage.assistantToolCalls(
    this.toolCalls, {
    this.content = '',
  })  : role = AiRole.assistant,
        toolCallId = null,
        isError = false;

  /// The answer to one [AiToolCall], fed back so the model can carry on.
  ///
  /// Carried as a user-role message because that is where two of the three
  /// providers put it; the third gets its own `role: "tool"` message. Send one
  /// per call the model made — the brokers coalesce them into whatever shape
  /// the provider expects, including Anthropic's requirement that every result
  /// for a turn ride in a *single* user message.
  const AiMessage.toolResult({
    required String this.toolCallId,
    required this.content,
    this.isError = false,
  })  : role = AiRole.user,
        toolCalls = const [];

  String get roleName => role == AiRole.user ? 'user' : 'assistant';

  /// True for a message built by [AiMessage.toolResult].
  bool get isToolResult => toolCallId != null;

  @override
  String toString() => toolCalls.isEmpty
      ? '${role.name}: $content'
      : '${role.name}: $content '
          '[${toolCalls.map((c) => c.name).join(', ')}]';
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
  /// retry-on-parse loop.
  ///
  /// **Honoured by every chat broker**, each in its own dialect: Anthropic
  /// takes the schema verbatim in `output_config.format`; OpenAI wraps it in
  /// a `response_format` with `strict: true`; Gemini gets
  /// `responseMimeType: 'application/json'` plus an OpenAPI-subset
  /// translation in `responseSchema`. Write it once, as ordinary JSON Schema,
  /// and let [toGeminiSchema] / [toOpenAiStrictSchema] reconcile the
  /// differences — including the one that cuts both ways, where OpenAI's
  /// strict mode *requires* the `additionalProperties: false` that Gemini
  /// rejects with a 400.
  ///
  /// The portable subset to write in: objects with `properties`, `required`
  /// and `additionalProperties: false`; arrays with `items`; `enum` for
  /// closed string sets; `type: ['string', 'null']` for nullable fields.
  /// Value bounds (`minLength`, `maximum`, `pattern`, …) are dropped on the
  /// way to Gemini — state those in the prompt instead. A schema Gemini
  /// cannot express at all (a recursive `$ref`, a `['string', 'number']`
  /// union) still yields JSON, just unconstrained.
  final Map<String, Object?>? jsonSchema;

  /// Mark the system prompt as a cacheable prefix. Worth it whenever the
  /// same system text is reused across calls — a long knowledge base sent
  /// on every turn, or a judge re-scoring the same prompt each round.
  final bool cacheSystem;

  /// Tools the model may call this turn. Null or empty sends nothing, which
  /// is what every request that predates tool calling does.
  ///
  /// **Honoured by every chat broker**, each in its own dialect: Anthropic
  /// takes `tools: [{name, description, input_schema}]`; OpenAI wraps each in
  /// `{type: 'function', function: {…}}`; Gemini nests them under a single
  /// `tools: [{functionDeclarations: […]}]` and wants the schema in its
  /// OpenAPI-3 subset.
  ///
  /// A turn that wants a tool comes back with [AiStopReason.toolUse] and the
  /// calls on [AiCompletion.toolCalls] — reachable from `chatDetailed` and
  /// from `streamDetailed`'s completion, not from the text-only `chat` and
  /// `stream`. Run them, then send the next request with the assistant turn
  /// ([AiMessage.assistantToolCalls]) and one [AiMessage.toolResult] per call
  /// appended to [messages].
  final List<AiTool>? tools;

  /// Whether the model may, must, or must not call one. Null means the field
  /// is not sent at all and the provider's own default applies. Ignored when
  /// [tools] is null or empty — a choice with nothing to choose from is a 400
  /// on OpenAI and Anthropic alike.
  final AiToolChoice? toolChoice;

  const ChatRequest({
    required this.system,
    required this.messages,
    this.temperature,
    this.maxTokens = 2048,
    this.effort,
    this.jsonSchema,
    this.cacheSystem = false,
    this.tools,
    this.toolChoice,
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
    List<AiTool>? tools,
    AiToolChoice? toolChoice,
  }) =>
      ChatRequest(
        system: system,
        messages: [AiMessage.user(user)],
        temperature: temperature,
        maxTokens: maxTokens,
        effort: effort,
        jsonSchema: jsonSchema,
        cacheSystem: cacheSystem,
        tools: tools,
        toolChoice: toolChoice,
      );
}
