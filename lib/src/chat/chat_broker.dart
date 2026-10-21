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
///
/// A provider implements [chatWithMeta] and [stream]; [chat], [complete]
/// and [completeWithMeta] are defaults built on [chatWithMeta], so a
/// class that `extends ChatBroker` gets them for free. A class that
/// `implements ChatBroker` must supply all five.
abstract class ChatBroker implements AiBroker {
  /// Single-shot. Returns the assistant's raw text. Same call as
  /// [completeWithMeta], keeping only [AiCompletion.text].
  Future<String> complete({
    required String apiKey,
    required String model,
    required String system,
    required String user,
    double temperature = 0.3,
    int maxTokens = 2048,
  }) async =>
      (await completeWithMeta(
        apiKey: apiKey,
        model: model,
        system: system,
        user: user,
        temperature: temperature,
        maxTokens: maxTokens,
      ))
          .text;

  /// Single-shot, returning the reply with why the model stopped and the
  /// token counts the provider reported. Use it to tell a reply cut off at
  /// [maxTokens] ([AiFinishReason.maxTokens]) from a complete one.
  Future<AiCompletion> completeWithMeta({
    required String apiKey,
    required String model,
    required String system,
    required String user,
    double temperature = 0.3,
    int maxTokens = 2048,
  }) =>
      chatWithMeta(
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
  /// Same call as [chatWithMeta], keeping only [AiCompletion.text].
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async =>
      (await chatWithMeta(apiKey: apiKey, model: model, request: request)).text;

  /// Multi-turn, returning the final turn's reply with why the model
  /// stopped and the token counts the provider reported. Every provider
  /// call goes through here; [chat], [complete] and [completeWithMeta]
  /// are built on it.
  Future<AiCompletion> chatWithMeta({
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
