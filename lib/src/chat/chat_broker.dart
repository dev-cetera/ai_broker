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
    double? temperature,
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
  ///
  /// Text-only by design: a turn that answers with a tool call has no text to
  /// return and throws, naming the tool and pointing here. Use [chatDetailed]
  /// whenever the request carries [ChatRequest.tools].
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  });

  /// Like [chat], but returns token accounting, the stop reason and any
  /// [AiCompletion.toolCalls] alongside the text. Prefer this anywhere the
  /// call costs money in a loop, where a refusal needs handling rather than an
  /// exception, or where the request declares tools — this is the only way to
  /// read what the model asked to call.
  ///
  /// The default implementation delegates to [chat] and reports zero tokens,
  /// so providers that expose no usage data still satisfy the interface.
  /// Override it wherever the provider does return accounting.
  Future<AiCompletion> chatDetailed({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    final text = await chat(apiKey: apiKey, model: model, request: request);
    return AiCompletion(
      text: text,
      model: model,
      stopReason: AiStopReason.endTurn,
    );
  }

  /// Token-streaming chat. Each event is an *incremental* delta —
  /// concatenating every event yields the same string [chat] would
  /// return. Closes the stream cleanly on end-of-message; errors are
  /// surfaced via the stream.
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  });

  /// Like [stream], but also reports what the turn cost and why it ended.
  /// The text still arrives incrementally — on
  /// [StreamedCompletion.deltas], the same events [stream] yields — while
  /// [StreamedCompletion.completion] resolves once the stream is done.
  ///
  /// This is what [chatDetailed] is to [chat]: use it anywhere a streamed
  /// turn has to be billed, where a mid-stream refusal needs to be told apart
  /// from a normal end, or where tools are in play — a streamed tool call
  /// arrives in fragments and can only be reported once complete, so it lands
  /// on [StreamedCompletion.completion] rather than on the deltas.
  ///
  /// The default implementation wraps [stream] and reports the accumulated
  /// text with zero tokens and [AiStopReason.endTurn], so providers whose
  /// stream carries no accounting still satisfy the interface. Override it
  /// wherever the wire format does carry usage.
  StreamedCompletion streamDetailed({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) =>
      StreamedCompletion.fromDeltas(
        deltas: stream(apiKey: apiKey, model: model, request: request),
        model: model,
      );
}
