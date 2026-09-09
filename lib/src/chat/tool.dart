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

/// One tool the model is allowed to call.
///
/// Declared once, in ordinary JSON Schema, and translated per provider on the
/// way out — Anthropic takes `input_schema`, OpenAI takes
/// `function.parameters`, Gemini takes `functionDeclarations[].parameters` in
/// the same OpenAPI-3 subset [toGeminiSchema] already produces for structured
/// output. Write the schema the way [ChatRequest.jsonSchema] documents and the
/// brokers reconcile the rest.
///
/// The package never *runs* a tool. A turn that wants one comes back with
/// [AiCompletion.stopReason] of [AiStopReason.toolUse] and the calls in
/// [AiCompletion.toolCalls]; the caller executes them and feeds each answer
/// back with [AiMessage.toolResult] on the next turn.
@immutable
class AiTool {
  /// What the model names when it calls this tool. Keep it to
  /// `[a-zA-Z0-9_-]` — every provider constrains the character set, and
  /// OpenAI and Anthropic both cap it at 64 characters.
  final String name;

  /// What the tool does, in prose. This is the only thing the model has to go
  /// on when deciding whether to call it, so it earns more care than the
  /// schema does.
  final String description;

  /// JSON Schema for the arguments — normally an object with `properties` and
  /// `required`.
  final Map<String, Object?> inputSchema;

  const AiTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  @override
  String toString() => 'AiTool($name)';
}

/// Whether the model may, must, or must not call a tool on this turn.
///
/// Null on [ChatRequest.toolChoice] means "do not send the field", which
/// leaves the provider on its own default — `auto` everywhere today, but the
/// default is theirs to change, and not sending it is the only way to say
/// "no opinion".
enum AiToolChoice {
  /// The model decides between answering and calling a tool.
  auto('auto'),

  /// Tools stay declared but the model must answer in text.
  none('none'),

  /// The model must call one of the declared tools. Anthropic spells this
  /// `any`; the wire strings differ per provider and the brokers map it.
  required('required');

  const AiToolChoice(this.wire);

  final String wire;
}

/// One call the model asked for: which tool, with what arguments.
///
/// [arguments] is always a decoded map. OpenAI puts a JSON **string** on the
/// wire and the broker parses it, so callers never string-match their way into
/// an argument — a malformed or absent payload arrives as an empty map rather
/// than as a half-parsed one.
@immutable
class AiToolCall {
  /// The id the result must quote back. Anthropic and OpenAI mint one;
  /// Gemini's wire format has no id at all, so [GeminiBroker] synthesises a
  /// deterministic one from the call's position and name.
  final String id;

  /// The [AiTool.name] being called.
  final String name;

  /// The decoded arguments. Empty when the model called a zero-argument tool —
  /// and also when the provider sent something unparseable, which is why a
  /// caller should validate rather than assume.
  final Map<String, Object?> arguments;

  /// Opaque provider state that has to be handed straight back with the call.
  ///
  /// Gemini's thinking models attach a `thoughtSignature` to every
  /// `functionCall` part and **reject the next turn with a 400 if it is not
  /// echoed verbatim** ("Function call is missing a thought_signature"). It is
  /// meaningless to this package — never parse it, never synthesise one, just
  /// carry it. Null for providers that do not use one.
  final String? providerSignature;

  const AiToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.providerSignature,
  });

  @override
  String toString() => 'AiToolCall($name, id: $id, args: $arguments)';
}

/// The message a text-only `chat` throws when the turn came back with no
/// text.
///
/// `chat` returns a `String`, so a turn whose entire answer is a tool call has
/// nothing to hand back. That is not a provider failure and not a bug in the
/// caller's prompt — it means the wrong method was called — so the exception
/// says so instead of reporting a bare empty reply. The [emptyPhrase] each
/// provider already used is kept verbatim, because that is the string people
/// have grepped their logs for.
String toolNoTextMessage(
  String provider,
  String emptyPhrase,
  List<AiToolCall> toolCalls,
) {
  if (toolCalls.isEmpty) return '$provider returned $emptyPhrase.';
  final names = toolCalls.map((c) => c.name).join(', ');
  return '$provider returned $emptyPhrase because the turn is a tool call '
      '($names). Use chatDetailed() and read AiCompletion.toolCalls.';
}

/// Normalises whatever a provider put in the arguments slot into a decoded
/// map. Shared by all three brokers so a caller sees one shape regardless of
/// who answered.
///
/// Anthropic and Gemini send a JSON object; OpenAI sends a JSON **string**,
/// which is the trap this exists to close — string-matching your way into an
/// argument works right up until a value contains the thing you matched on.
///
/// Anything that is not an object — null, a bare array, a truncated string
/// from a stream that was cut off — becomes an empty map. A tool call is
/// worth surfacing even when its arguments did not survive the wire; the
/// caller validates before executing either way.
Map<String, Object?> decodeToolArguments(Object? raw) {
  if (raw == null) return const {};
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const {};
    try {
      return decodeToolArguments(jsonDecode(trimmed));
    } on FormatException {
      return const {};
    }
  }
  if (raw is Map<String, Object?>) {
    return <String, Object?>{...raw};
  }
  if (raw is Map<Object?, Object?>) {
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
  return const {};
}
