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

/// Implements only the primitives ([chatWithMeta] + [stream]), so
/// [ChatBroker.chat], [ChatBroker.complete] and
/// [ChatBroker.completeWithMeta] come from the defaults on [ChatBroker].
/// Captures the [ChatRequest] each call sends.
class _CapturingChat extends ChatBroker {
  ChatRequest? captured;

  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  @override
  Future<AiCompletion> chatWithMeta({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    captured = request;
    return const AiCompletion(
      text: '<<captured>>',
      rawFinishReason: 'max_tokens',
      finishReason: AiFinishReason.maxTokens,
      inputTokens: 1,
      outputTokens: 2,
    );
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) =>
      const Stream<String>.empty();
}

void main() {
  group('ChatBroker.complete default impl', () {
    test('delegates to chatWithMeta() with a single-user-message ChatRequest',
        () async {
      final b = _CapturingChat();
      final out = await b.complete(
        apiKey: 'k',
        model: 'm',
        system: 'system prompt',
        user: 'hello',
      );
      expect(out, '<<captured>>');
      expect(b.captured, isNotNull);
      expect(b.captured!.system, 'system prompt');
      expect(b.captured!.messages, hasLength(1));
      expect(b.captured!.messages.single.content, 'hello');
      expect(b.captured!.messages.single.role, AiRole.user);
    });

    test('forwards temperature and maxTokens', () async {
      final b = _CapturingChat();
      await b.complete(
        apiKey: 'k',
        model: 'm',
        system: '',
        user: 'q',
        temperature: 0.7,
        maxTokens: 512,
      );
      expect(b.captured!.temperature, 0.7);
      expect(b.captured!.maxTokens, 512);
    });
  });

  group('ChatBroker *WithMeta defaults', () {
    test('completeWithMeta sends one user message through chatWithMeta',
        () async {
      final b = _CapturingChat();
      final out = await b.completeWithMeta(
        apiKey: 'k',
        model: 'm',
        system: 'sys',
        user: 'hi',
        temperature: 0.5,
        maxTokens: 64,
      );
      expect(out.text, '<<captured>>');
      expect(out.finishReason, AiFinishReason.maxTokens);
      final sent = b.captured!;
      expect(sent.system, 'sys');
      expect(sent.messages.single.content, 'hi');
      expect(sent.temperature, 0.5);
      expect(sent.maxTokens, 64);
    });

    test('complete and chat return the text of the meta call', () async {
      final b = _CapturingChat();
      expect(
        await b.complete(apiKey: 'k', model: 'm', system: 's', user: 'u'),
        '<<captured>>',
      );
      expect(
        await b.chat(
          apiKey: 'k',
          model: 'm',
          request: ChatRequest.single(system: 's', user: 'u'),
        ),
        '<<captured>>',
      );
    });
  });
}
