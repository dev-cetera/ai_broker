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

/// How hard a model should work on a turn.
///
/// This is the replacement for `temperature` on current-generation models,
/// which reject sampling parameters outright. Higher effort means more
/// internal reasoning and more tokens; `low` is the right default for
/// short, factual, latency-sensitive replies.
///
/// Maps to Anthropic's `output_config.effort`. Providers that have no
/// equivalent ignore it.
enum AiEffort {
  low('low'),
  medium('medium'),
  high('high'),
  xhigh('xhigh'),
  max('max');

  const AiEffort(this.wire);

  final String wire;

  static AiEffort? fromWireOrNull(String? wire) {
    if (wire == null) return null;
    for (final v in values) {
      if (v.wire == wire) return v;
    }
    return null;
  }
}

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
/// stopped, how many tokens it used, which model served it and any tools
/// it asked to call. Returned by [ChatBroker.chatWithMeta] and
/// [ChatBroker.completeWithMeta], and by [StreamedCompletion.completion].
@immutable
class AiCompletion {
  const AiCompletion({
    required this.text,
    this.model = '',
    this.rawFinishReason,
    this.finishReason,
    this.inputTokens,
    this.outputTokens,
    this.thinkingTokens,
    this.cacheReadInputTokens = 0,
    this.cacheCreationInputTokens = 0,
    this.toolCalls = const [],
  });

  /// The concatenated text of every text block in the response. Empty when
  /// the model refused, or when it answered only with tool calls.
  final String text;

  /// The model that actually served the turn, or `''` when the provider
  /// did not say. Worth reading rather than assuming: a server-side
  /// fallback can answer on a different model than the one requested.
  final String model;

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

  /// Prompt-cache accounting. A run that caches its system prefix correctly
  /// shows a large [cacheReadInputTokens] from the second call onward; a
  /// persistent zero means something in the prefix is changing per request.
  final int cacheReadInputTokens;
  final int cacheCreationInputTokens;

  /// The tools the model asked to call, in the order it asked for them.
  /// Empty on an ordinary turn — which is every turn where the request
  /// declared no [ChatRequest.tools].
  ///
  /// A model can ask for several at once, and asking is all it does: nothing
  /// here has been executed. Run them, then send the next request with
  /// [AiMessage.assistantToolCalls] followed by one [AiMessage.toolResult]
  /// per entry.
  final List<AiToolCall> toolCalls;

  /// True when the provider refused or filtered the reply
  /// ([AiFinishReason.safety]). A refusal arrives as a normal response, not
  /// an error, and [text] may be empty.
  bool get isRefusal => finishReason == AiFinishReason.safety;

  /// True when the model stopped in order to call a tool. Prefer this over
  /// testing [toolCalls] for emptiness: the two agree on every provider, but
  /// this is the one that says *why* the turn ended.
  bool get wantsTool => finishReason == AiFinishReason.toolUse;

  /// True when the reply was cut off by the token ceiling, which usually
  /// means the caller's `maxTokens` is too low rather than that the model
  /// finished.
  bool get isTruncated => finishReason == AiFinishReason.maxTokens;

  @override
  bool operator ==(Object other) =>
      other is AiCompletion &&
      other.text == text &&
      other.model == model &&
      other.rawFinishReason == rawFinishReason &&
      other.finishReason == finishReason &&
      other.inputTokens == inputTokens &&
      other.outputTokens == outputTokens &&
      other.thinkingTokens == thinkingTokens &&
      other.cacheReadInputTokens == cacheReadInputTokens &&
      other.cacheCreationInputTokens == cacheCreationInputTokens &&
      _sameCalls(other.toolCalls, toolCalls);

  static bool _sameCalls(List<AiToolCall> a, List<AiToolCall> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        text,
        model,
        rawFinishReason,
        finishReason,
        inputTokens,
        outputTokens,
        thinkingTokens,
        cacheReadInputTokens,
        cacheCreationInputTokens,
        Object.hashAll(toolCalls),
      );

  @override
  String toString() => 'AiCompletion(model: $model, '
      'finishReason: $rawFinishReason, '
      'inputTokens: $inputTokens, outputTokens: $outputTokens, '
      'thinkingTokens: $thinkingTokens, '
      'cacheRead: $cacheReadInputTokens, text: ${text.length} chars'
      '${toolCalls.isEmpty ? '' : ', tools: ${toolCalls.length}'})';
}

/// A streaming turn: the text as it arrives, plus the accounting that is only
/// known once the stream ends.
///
/// [ChatBroker.stream] hands back text and nothing else, which is enough to
/// paint a UI and useless for billing. [ChatBroker.streamWithMeta] returns
/// this instead — drain [deltas] exactly as before, then await [completion]:
///
/// ```dart
/// final turn = broker.streamWithMeta(apiKey: key, model: m, request: r);
/// await for (final delta in turn.deltas) {
///   stdout.write(delta);
/// }
/// final done = await turn.completion;
/// if (done.isRefusal) log.warn('declined');
/// meter.record(done.inputTokens, done.outputTokens);
/// ```
///
/// [deltas] is a normal single-subscription stream — listen once, `await for`
/// it, cancel it. Nothing is sent until it is listened to, and nothing is
/// buffered ahead of the consumer.
class StreamedCompletion {
  /// Wraps a text stream that already carries its own accounting. Providers
  /// override [ChatBroker.streamWithMeta] and build this directly.
  const StreamedCompletion({
    required this.deltas,
    required this.completion,
  });

  /// Best-effort wrapper for a plain `Stream<String>` of text deltas: the
  /// accumulated text is reported with zero tokens and [finishReason], because
  /// a bare delta stream carries nothing else.
  ///
  /// This is what [ChatBroker.streamWithMeta] falls back to, and what any
  /// `ChatBroker` implementation that has no usage data on the wire should
  /// return.
  factory StreamedCompletion.fromDeltas({
    required Stream<String> deltas,
    required String model,
    AiFinishReason? finishReason = AiFinishReason.stop,
  }) {
    final completer = Completer<AiCompletion>();
    // A caller that only drains the text already saw the failure there;
    // without a listener the same error would also be reported as an
    // unhandled async error.
    completer.future.ignore();
    final buf = StringBuffer();
    Stream<String> tap() async* {
      try {
        // `yield*`, not `await for`: it keeps the generator parked on a yield
        // point, so a consumer that cancels mid-reply gets its cancellation
        // acknowledged and the `finally` below still settles [completion].
        // The price is that errors bypass the enclosing catch, hence the
        // `handleError` hop — it fails [completion] before re-throwing at the
        // consumer.
        yield* deltas.map((delta) {
          buf.write(delta);
          return delta;
        }).handleError((Object e, StackTrace st) {
          if (!completer.isCompleted) completer.completeError(e, st);
          Error.throwWithStackTrace(e, st);
        });
      } finally {
        if (!completer.isCompleted) {
          completer.complete(
            AiCompletion(
              text: buf.toString().trim(),
              model: model,
              finishReason: finishReason,
            ),
          );
        }
      }
    }

    return StreamedCompletion(deltas: tap(), completion: completer.future);
  }

  /// The reply, token by token. Same events [ChatBroker.stream] yields:
  /// incremental deltas, so concatenating them rebuilds the full text.
  final Stream<String> deltas;

  /// Resolves when [deltas] ends, carrying the token usage, the model that
  /// actually served the turn, and the stop reason — which is the only way to
  /// tell a refusal from a normal end.
  ///
  /// Completes with an error if the stream failed; the same error also
  /// reaches whoever is listening to [deltas]. Consuming [deltas] is what
  /// drives this: abandon the stream part-way and this resolves with whatever
  /// arrived before the cancellation, never listen at all and it never
  /// resolves, because the request is never sent.
  final Future<AiCompletion> completion;
}
