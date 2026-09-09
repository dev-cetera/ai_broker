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

import 'package:ai_broker/ai_broker.dart';
import 'package:test/test.dart';

/// Records the chat request the LlmTranslator hands over so we can
/// assert on the system prompt structure.
class _RecordingChat implements ChatBroker {
  ChatRequest? captured;
  String? capturedModel;
  String answer = '  bonjour  '; // includes whitespace to verify trimming.

  @override
  String get id => 'openai';
  @override
  String get label => 'Rec';
  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  @override
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

  @override
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    capturedModel = model;
    captured = request;
    return answer;
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) =>
      const Stream<String>.empty();

  @override
  Future<AiCompletion> chatDetailed({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async =>
      AiCompletion(
        text: await chat(apiKey: apiKey, model: model, request: request),
        model: model,
        stopReason: AiStopReason.endTurn,
      );

  @override
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

void main() {
  group('LlmTranslator', () {
    test('id defaults to "llm:<chatBroker.id>"', () {
      final t = LlmTranslator(
        chatBroker: _RecordingChat(),
        defaultModel: 'm',
      );
      expect(t.id, 'llm:openai');
      expect(t.label, contains('Rec'));
    });

    test('id can be overridden', () {
      final t = LlmTranslator(
        chatBroker: _RecordingChat(),
        defaultModel: 'm',
        idOverride: 'translator',
      );
      expect(t.id, 'translator');
    });

    test('builds a translation prompt and returns the trimmed answer',
        () async {
      final chat = _RecordingChat();
      final t = LlmTranslator(chatBroker: chat, defaultModel: 'm');
      final result = await t.translate(
        apiKey: 'k',
        text: 'hello',
        to: 'fr',
      );
      expect(result.translated, 'bonjour'); // trimmed
      expect(result.modelUsed, 'm');
      expect(chat.captured, isNotNull);
      expect(chat.captured!.system, contains('to fr'));
      expect(chat.captured!.messages.single.content, 'hello');
    });

    test('prompt includes every supplied hint', () async {
      final chat = _RecordingChat();
      final t = LlmTranslator(chatBroker: chat, defaultModel: 'm');
      await t.translate(
        apiKey: 'k',
        text: 'the catalyst',
        to: 'fr',
        from: 'en',
        domain: 'chemistry',
        tone: 'formal',
        glossary: const {'catalyst': 'catalyseur'},
        context: 'this is a research paper.',
      );
      final sys = chat.captured!.system;
      expect(sys, contains('from en to fr'));
      expect(sys.toLowerCase(), contains('chemistry'));
      expect(sys.toLowerCase(), contains('formal'));
      expect(sys, contains('catalyst'));
      expect(sys, contains('catalyseur'));
      expect(sys, contains('research paper'));
    });

    test('uses defaultModel when no override is passed', () async {
      final chat = _RecordingChat();
      final t = LlmTranslator(chatBroker: chat, defaultModel: 'default-m');
      await t.translate(apiKey: 'k', text: 'x', to: 'fr');
      expect(chat.capturedModel, 'default-m');
    });

    test('model: override beats defaultModel', () async {
      final chat = _RecordingChat();
      final t = LlmTranslator(chatBroker: chat, defaultModel: 'default-m');
      await t.translate(apiKey: 'k', text: 'x', to: 'fr', model: 'override-m');
      expect(chat.capturedModel, 'override-m');
    });

    test('listModels delegates to the underlying chat broker', () async {
      final chat = _RecordingChat();
      final t = LlmTranslator(chatBroker: chat, defaultModel: 'm');
      expect(await t.listModels('k'), isEmpty);
    });

    test('translator is recognised as a TranslateBroker', () {
      final t = LlmTranslator(
        chatBroker: _RecordingChat(),
        defaultModel: 'm',
      );
      expect(t, isA<TranslateBroker>());
    });
  });
}
