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

/// Chat / completion / streaming capability. Implemented by every
/// chat-capable provider in this package (`OpenAiBroker`,
/// `AnthropicBroker`, `GeminiBroker`).
abstract class ChatBroker implements AiBroker {
  /// Single-shot. Returns the assistant's raw text.
  Future<String> complete({
    required String apiKey,
    required String model,
    required String system,
    required String user,
    double temperature = 0.3,
    int maxTokens = 2048,
  }) =>
      chat(
        apiKey: apiKey,
        model: model,
        request: ChatRequest.single(
          system: system,
          user: user,
          temperature: temperature,
          maxTokens: maxTokens,
        ),
      );

  /// Multi-turn. Returns the assistant's raw text for the final turn.
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  });

  /// Token-streaming chat. Each event is an *incremental* delta —
  /// concatenating every event yields the same string [chat] would
  /// return. Closes the stream cleanly on end-of-message; errors are
  /// surfaced via the stream.
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  });
}
