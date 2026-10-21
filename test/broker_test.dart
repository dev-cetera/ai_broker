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

/// Implements only the primitives, so every other method comes from the
/// defaults on [AiBroker].
class _StubBroker extends AiBroker {
  _StubBroker(this.id, this.label);

  @override
  final String id;

  @override
  final String label;

  ChatRequest? lastRequest;

  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  @override
  Future<AiCompletion> chatWithMeta({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    lastRequest = request;
    return const AiCompletion(
      text: 'reply',
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
  group('AiBrokerRegistry', () {
    setUp(() => AiBrokerRegistry.instance.clear());
    tearDown(() => AiBrokerRegistry.instance.clear());

    test('exposes a single shared instance', () {
      expect(
        identical(AiBrokerRegistry.instance, AiBrokerRegistry.instance),
        isTrue,
      );
    });

    test('register and lookup by id', () {
      final broker = _StubBroker('openai', 'OpenAI');
      AiBrokerRegistry.instance.register(broker);
      expect(AiBrokerRegistry.instance.lookup('openai'), same(broker));
    });

    test('lookup returns null for an unknown id', () {
      expect(AiBrokerRegistry.instance.lookup('missing'), isNull);
    });

    test('register replaces a previously registered broker with the same id',
        () {
      final first = _StubBroker('openai', 'A');
      final second = _StubBroker('openai', 'B');
      AiBrokerRegistry.instance.register(first);
      AiBrokerRegistry.instance.register(second);
      expect(AiBrokerRegistry.instance.lookup('openai'), same(second));
      expect(AiBrokerRegistry.instance.all, hasLength(1));
    });

    test('unregister removes the broker', () {
      AiBrokerRegistry.instance.register(_StubBroker('openai', 'OpenAI'));
      AiBrokerRegistry.instance.unregister('openai');
      expect(AiBrokerRegistry.instance.lookup('openai'), isNull);
    });

    test('all returns every registered broker', () {
      AiBrokerRegistry.instance.register(_StubBroker('openai', 'OpenAI'));
      AiBrokerRegistry.instance.register(_StubBroker('anthropic', 'Anthropic'));
      expect(
        AiBrokerRegistry.instance.all.map((b) => b.id),
        containsAll(<String>['openai', 'anthropic']),
      );
    });

    test('all returns an unmodifiable view', () {
      AiBrokerRegistry.instance.register(_StubBroker('openai', 'OpenAI'));
      final view = AiBrokerRegistry.instance.all;
      expect(() => view.add(_StubBroker('x', 'X')), throwsUnsupportedError);
    });

    test('clear empties the registry', () {
      AiBrokerRegistry.instance.register(_StubBroker('openai', 'OpenAI'));
      AiBrokerRegistry.instance.register(_StubBroker('gemini', 'Gemini'));
      AiBrokerRegistry.instance.clear();
      expect(AiBrokerRegistry.instance.all, isEmpty);
    });
  });

  group('AiBrokerException', () {
    test('formats with status code', () {
      expect(
        const AiBrokerException('boom', statusCode: 500).toString(),
        'HTTP 500: boom',
      );
    });

    test('formats without status code', () {
      expect(const AiBrokerException('boom').toString(), 'boom');
    });

    test('is an Exception', () {
      expect(const AiBrokerException('x'), isA<Exception>());
    });
  });

  group('AiBroker defaults', () {
    test('completeWithMeta sends one user message through chatWithMeta',
        () async {
      final b = _StubBroker('stub', 'Stub');
      final out = await b.completeWithMeta(
        apiKey: 'k',
        model: 'm',
        system: 'sys',
        user: 'hi',
        temperature: 0.5,
        maxTokens: 64,
      );
      expect(out.text, 'reply');
      expect(out.finishReason, AiFinishReason.maxTokens);
      final sent = b.lastRequest!;
      expect(sent.system, 'sys');
      expect(sent.messages.single.content, 'hi');
      expect(sent.temperature, 0.5);
      expect(sent.maxTokens, 64);
    });

    test('complete and chat return the text of the meta call', () async {
      final b = _StubBroker('stub', 'Stub');
      expect(
        await b.complete(apiKey: 'k', model: 'm', system: 's', user: 'u'),
        'reply',
      );
      expect(
        await b.chat(
          apiKey: 'k',
          model: 'm',
          request: ChatRequest.single(system: 's', user: 'u'),
        ),
        'reply',
      );
    });
  });

  group('AiCompletion', () {
    test('compares by value', () {
      const a = AiCompletion(
        text: 't',
        rawFinishReason: 'STOP',
        finishReason: AiFinishReason.stop,
        inputTokens: 1,
        outputTokens: 2,
        thinkingTokens: 0,
      );
      const b = AiCompletion(
        text: 't',
        rawFinishReason: 'STOP',
        finishReason: AiFinishReason.stop,
        inputTokens: 1,
        outputTokens: 2,
        thinkingTokens: 0,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          const AiCompletion(
            text: 't',
            rawFinishReason: 'MAX_TOKENS',
            finishReason: AiFinishReason.maxTokens,
            inputTokens: 1,
            outputTokens: 2,
            thinkingTokens: 0,
          ),
        ),
      );
    });
  });
}
