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

/// Why a provider stopped writing, in one vocabulary for every broker.
///
/// Each broker maps its provider's documented values onto these members.
/// A value it does not map (a provider's own "other" / "unspecified", or a
/// value added after this package was written) leaves
/// [AiCompletion.finishReason] `null`; [AiCompletion.rawFinishReason] still
/// carries the provider's string, so nothing is hidden.
enum AiFinishReason {
  /// The model finished on its own. Gemini `STOP`, Anthropic `end_turn`,
  /// OpenAI `stop`.
  stop,

  /// The model hit one of the caller's stop sequences. Anthropic
  /// `stop_sequence`. (Gemini and OpenAI report this case as [stop].)
  stopSequence,

  /// The reply was cut off at the output-token limit. Gemini `MAX_TOKENS`,
  /// Anthropic `max_tokens`, OpenAI `length`.
  maxTokens,

  /// The reply was blocked or cut off by a safety filter. Gemini `SAFETY`,
  /// `BLOCKLIST`, `PROHIBITED_CONTENT`, `SPII`, `IMAGE_SAFETY`,
  /// `IMAGE_PROHIBITED_CONTENT`; Anthropic `refusal`; OpenAI
  /// `content_filter`.
  safety,

  /// The reply was stopped for reciting training data. Gemini `RECITATION`,
  /// `IMAGE_RECITATION`.
  recitation,

  /// The model stopped to call a tool. Anthropic `tool_use`, OpenAI
  /// `tool_calls` / `function_call`.
  toolUse,

  /// The model produced a tool call the provider rejected. Gemini
  /// `MALFORMED_FUNCTION_CALL`, `UNEXPECTED_TOOL_CALL`,
  /// `TOO_MANY_TOOL_CALLS`.
  toolCallError,

  /// A long-running turn was paused and can be continued. Anthropic
  /// `pause_turn`.
  pauseTurn,

  /// The conversation outgrew the model's context window. Anthropic
  /// `model_context_window_exceeded`.
  contextWindowExceeded,

  /// The prompt or reply is in a language the model does not support.
  /// Gemini `LANGUAGE`.
  unsupportedLanguage,
}

/// The assistant's reply plus what the provider said about it: why it
/// stopped and how many tokens it used. Returned by
/// [AiBroker.completeWithMeta] and [AiBroker.chatWithMeta].
@immutable
class AiCompletion {
  /// The assistant's text, exactly as [AiBroker.complete] returns it.
  final String text;

  /// The provider's finish / stop reason as sent (`'STOP'`, `'end_turn'`,
  /// `'length'`, …), or `null` when the response did not include one.
  final String? rawFinishReason;

  /// [rawFinishReason] in the shared vocabulary, or `null` when the
  /// response had no reason or the broker does not map that value.
  final AiFinishReason? finishReason;

  /// Prompt tokens the provider counted, or `null` when not reported.
  final int? inputTokens;

  /// Output tokens the provider counted, including any thinking / reasoning
  /// tokens (as all three providers bill them), or `null` when not
  /// reported.
  final int? outputTokens;

  /// The part of [outputTokens] spent on thinking / reasoning, or `null`
  /// when the provider does not report it separately (Anthropic never
  /// does).
  final int? thinkingTokens;

  const AiCompletion({
    required this.text,
    required this.rawFinishReason,
    required this.finishReason,
    this.inputTokens,
    this.outputTokens,
    this.thinkingTokens,
  });

  @override
  bool operator ==(Object other) =>
      other is AiCompletion &&
      other.text == text &&
      other.rawFinishReason == rawFinishReason &&
      other.finishReason == finishReason &&
      other.inputTokens == inputTokens &&
      other.outputTokens == outputTokens &&
      other.thinkingTokens == thinkingTokens;

  @override
  int get hashCode => Object.hash(
        text,
        rawFinishReason,
        finishReason,
        inputTokens,
        outputTokens,
        thinkingTokens,
      );

  @override
  String toString() => 'AiCompletion(finishReason: $rawFinishReason, '
      'inputTokens: $inputTokens, outputTokens: $outputTokens, '
      'thinkingTokens: $thinkingTokens, text: ${text.length} chars)';
}
