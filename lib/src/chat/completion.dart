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

/// Why a turn stopped. `refusal` is the one that surprises people: it
/// arrives as a normal HTTP 200, not an error, and the content may be empty.
enum AiStopReason {
  endTurn('end_turn'),
  maxTokens('max_tokens'),
  stopSequence('stop_sequence'),
  toolUse('tool_use'),
  pauseTurn('pause_turn'),
  refusal('refusal'),
  unknown('');

  const AiStopReason(this.wire);

  final String wire;

  static AiStopReason fromWire(String? wire) {
    if (wire == null) return AiStopReason.unknown;
    for (final v in values) {
      if (v.wire == wire) return v;
    }
    return AiStopReason.unknown;
  }
}

/// A completed turn, with the accounting a caller needs to bill, cache-tune
/// and debug it.
///
/// [ChatBroker.chat] returns only the text; use [ChatBroker.chatDetailed]
/// when token counts or the stop reason matter — which, for anything that
/// runs in a loop or costs money per call, is usually.
@immutable
class AiCompletion {
  const AiCompletion({
    required this.text,
    required this.model,
    required this.stopReason,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadInputTokens = 0,
    this.cacheCreationInputTokens = 0,
    this.toolCalls = const [],
  });

  /// The concatenated text of every text block in the response. Empty when
  /// the model refused.
  final String text;

  /// The model that actually served the turn. Worth reading rather than
  /// assuming: a server-side fallback can answer on a different model than
  /// the one requested.
  final String model;

  final AiStopReason stopReason;

  final int inputTokens;
  final int outputTokens;

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

  bool get isRefusal => stopReason == AiStopReason.refusal;

  /// True when the model stopped in order to call a tool. Prefer this over
  /// testing [toolCalls] for emptiness: the two agree on every provider, but
  /// this is the one that says *why* the turn ended.
  bool get wantsTool => stopReason == AiStopReason.toolUse;

  /// True when the reply was cut off by the token ceiling, which usually
  /// means the caller's `maxTokens` is too low rather than that the model
  /// finished.
  bool get isTruncated => stopReason == AiStopReason.maxTokens;

  @override
  String toString() => 'AiCompletion(model: $model, stop: ${stopReason.wire}, '
      'in: $inputTokens, out: $outputTokens, '
      'cacheRead: $cacheReadInputTokens, chars: ${text.length}'
      '${toolCalls.isEmpty ? '' : ', tools: ${toolCalls.length}'})';
}

/// A streaming turn: the text as it arrives, plus the accounting that is only
/// known once the stream ends.
///
/// [ChatBroker.stream] hands back text and nothing else, which is enough to
/// paint a UI and useless for billing. [ChatBroker.streamDetailed] returns
/// this instead — drain [deltas] exactly as before, then await [completion]:
///
/// ```dart
/// final turn = broker.streamDetailed(apiKey: key, model: m, request: r);
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
  /// override [ChatBroker.streamDetailed] and build this directly.
  const StreamedCompletion({
    required this.deltas,
    required this.completion,
  });

  /// Best-effort wrapper for a plain `Stream<String>` of text deltas: the
  /// accumulated text is reported with zero tokens and [stopReason], because
  /// a bare delta stream carries nothing else.
  ///
  /// This is what [ChatBroker.streamDetailed] falls back to, and what any
  /// `ChatBroker` implementation that has no usage data on the wire should
  /// return.
  factory StreamedCompletion.fromDeltas({
    required Stream<String> deltas,
    required String model,
    AiStopReason stopReason = AiStopReason.endTurn,
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
              stopReason: stopReason,
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
