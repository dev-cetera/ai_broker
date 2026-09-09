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

  bool get isRefusal => stopReason == AiStopReason.refusal;

  /// True when the reply was cut off by the token ceiling, which usually
  /// means the caller's `maxTokens` is too low rather than that the model
  /// finished.
  bool get isTruncated => stopReason == AiStopReason.maxTokens;

  @override
  String toString() => 'AiCompletion(model: $model, stop: ${stopReason.wire}, '
      'in: $inputTokens, out: $outputTokens, '
      'cacheRead: $cacheReadInputTokens, chars: ${text.length})';
}
