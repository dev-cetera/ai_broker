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

import 'dart:typed_data';

import '/_common.dart';

/// Wraps [AiBroker.embed] with batching so callers can hand it an
/// arbitrary number of inputs without worrying about per-provider
/// per-call ceilings.
///
/// Per-provider per-call limits this enforces (the broker itself just
/// forwards your list):
/// - OpenAI `text-embedding-3-*`: ≤ 2048 inputs **and** ≤ 300k tokens
///   per request, ≤ 8191 tokens per individual input.
/// - Gemini `text-embedding-004`: 100 per call.
///
/// The batcher caps each call by **both** [batchSize] (input count) and
/// [charBudget] (sum of input lengths). [charBudget] is a coarse proxy
/// for tokens: prose tokenises at ~4 chars/token but code, JSON, and
/// markdown can hit 2 chars/token. The default 250k char ceiling stays
/// safely under OpenAI's 300k token limit even for code-heavy content.
class Embedder {
  final EmbedBroker broker;
  final String apiKey;
  final String model;
  final int batchSize;
  final int charBudget;

  const Embedder({
    required this.broker,
    required this.apiKey,
    required this.model,
    this.batchSize = 100,
    this.charBudget = 250000,
  })  : assert(batchSize > 0),
        assert(charBudget > 0);

  /// Stable id of the underlying broker — `'openai'`, `'gemini'`. Useful
  /// for tagging the resulting vectors with their provenance.
  String get providerId => broker.id;

  /// Embeds every input. Output vectors are in the same order as [inputs].
  /// Splits into batches that respect both [batchSize] and [charBudget].
  Future<List<Float32List>> embedAll(List<String> inputs) async {
    if (inputs.isEmpty) return const [];
    final out = <Float32List>[];
    var i = 0;
    while (i < inputs.length) {
      var end = i;
      var batchChars = 0;
      while (end < inputs.length && (end - i) < batchSize) {
        final nextLen = inputs[end].length;
        // Always include the first input in a batch even if it alone
        // exceeds the budget — the provider will reject and surface a
        // clean error, which is better than a silent infinite loop.
        if (end > i && batchChars + nextLen > charBudget) break;
        batchChars += nextLen;
        end++;
      }
      final batch = inputs.sublist(i, end);
      final vectors = await broker.embed(
        apiKey: apiKey,
        model: model,
        inputs: batch,
      );
      for (final v in vectors) {
        out.add(Float32List.fromList(v));
      }
      i = end;
    }
    return out;
  }

  /// Convenience: embed a single string.
  Future<Float32List> embedOne(String input) async {
    final out = await embedAll([input]);
    return out.first;
  }
}
