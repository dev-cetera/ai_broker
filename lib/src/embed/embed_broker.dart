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

/// Text-embedding capability. Implemented by `OpenAiBroker` and
/// `GeminiBroker`; **not** by `AnthropicBroker` (Anthropic doesn't
/// host first-party embeddings — pair Anthropic with OpenAI or Gemini
/// for the embed side).
abstract class EmbedBroker implements AiBroker {
  /// Embeds one or more texts into vectors of the model's native
  /// dimension. Returns one vector per input, same order as [inputs];
  /// all vectors share the same length.
  ///
  /// Per-call input limits are provider-specific (OpenAI: ≤2048 inputs,
  /// ≤8191 tokens each, ≤300k tokens per request; Gemini: ≤100 per
  /// call). Callers needing batching above those ceilings should use
  /// the higher-level `Embedder` from `lib/src/embed/`.
  ///
  /// Throws [AiBrokerException] for transport / response failures.
  Future<List<List<double>>> embed({
    required String apiKey,
    required String model,
    required List<String> inputs,
  });
}
