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
/// `OpenAiCompatibleBroker`, `DeepSeekBroker`, `AnthropicBroker`,
/// `GeminiBroker`).
///
/// A provider implements [chatWithMeta] and [stream]; [chat], [complete],
/// [completeWithMeta] and [streamWithMeta] are defaults, so a class that
/// `extends ChatBroker` gets them for free. A class that
/// `implements ChatBroker` must supply all of them.
abstract class ChatBroker implements AiBroker {
  /// Single-shot. Returns the assistant's raw text. Same call as
  /// [completeWithMeta], keeping only [AiCompletion.text].
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

  /// Single-shot, returning the reply with why the model stopped and the
  /// token counts the provider reported. Use it to tell a reply cut off at
  /// [maxTokens] ([AiFinishReason.maxTokens]) from a complete one.
  Future<AiCompletion> completeWithMeta({
    required String apiKey,
    required String model,
    required String system,
    required String user,
    double? temperature,
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
  ///
  /// Text-only by design: a turn with no text (a refusal, or a reply made
  /// only of tool calls) throws [AiBrokerException], naming the tool and
  /// pointing at [chatWithMeta]. Use [chatWithMeta] whenever the request
  /// carries [ChatRequest.tools].
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    final result = await chatWithMeta(
      apiKey: apiKey,
      model: model,
      request: request,
    );
    if (result.text.isEmpty) {
      final reason = result.rawFinishReason;
      throw AiBrokerException(
        result.isRefusal
            ? '$providerName declined this request (finish reason: $reason).'
            : result.toolCalls.isEmpty && reason != null
                ? '$providerName returned $emptyReplyPhrase '
                    '(finish reason: $reason).'
                : toolNoTextMessage(
                    providerName,
                    emptyReplyPhrase,
                    result.toolCalls,
                  ),
      );
    }
    return result.text;
  }

  /// The name [chat] uses in its errors. Defaults to [label]; brokers
  /// override it to keep the wording their errors have always had.
  @protected
  String get providerName => label;

  /// What [chat] says came back when a turn has no text (`'empty text'`,
  /// or `'empty content'` for OpenAI-style APIs), so logs grepped for the
  /// old message still match.
  @protected
  String get emptyReplyPhrase => 'empty text';

  /// Multi-turn, returning the final turn's reply with token accounting,
  /// why the model stopped, the serving model and any
  /// [AiCompletion.toolCalls]. Every provider call goes through here;
  /// [chat], [complete] and [completeWithMeta] are built on it.
  ///
  /// A refusal is reported, not thrown: [AiCompletion.isRefusal] is true
  /// and the text may be empty.
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

  /// Like [stream], but also reports what the turn cost and why it ended.
  /// The text still arrives incrementally — on
  /// [StreamedCompletion.deltas], the same events [stream] yields — while
  /// [StreamedCompletion.completion] resolves once the stream is done.
  ///
  /// This is what [chatWithMeta] is to [chat]: use it anywhere a streamed
  /// turn has to be billed, where a mid-stream refusal needs to be told apart
  /// from a normal end, or where tools are in play — a streamed tool call
  /// arrives in fragments and can only be reported once complete, so it lands
  /// on [StreamedCompletion.completion] rather than on the deltas.
  ///
  /// The default implementation wraps [stream] and reports the accumulated
  /// text with zero tokens and [AiFinishReason.stop], so providers whose
  /// stream carries no accounting still satisfy the interface. Override it
  /// wherever the wire format does carry usage.
  StreamedCompletion streamWithMeta({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) =>
      StreamedCompletion.fromDeltas(
        deltas: stream(apiKey: apiKey, model: model, request: request),
        model: model,
      );
}
