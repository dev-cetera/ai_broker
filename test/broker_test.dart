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

class _StubBroker implements AiBroker {
  _StubBroker(this.id, this.label);

  @override
  final String id;

  @override
  final String label;

  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  @override
  Future<String> complete({
    required String apiKey,
    required String model,
    required String system,
    required String user,
    double temperature = 0.3,
    int maxTokens = 2048,
  }) async =>
      '';

  @override
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async =>
      '';

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
}
