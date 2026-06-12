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

/// Bare [AiBroker] for registry tests — implements only the base
/// interface; no chat / embed / etc. The registry's contract is that it
/// stores and returns `AiBroker`s by id, regardless of capability.
class _StubBroker implements AiBroker {
  _StubBroker(this.id, this.label);

  @override
  final String id;

  @override
  final String label;

  @override
  Future<List<String>> listModels(String apiKey) async => const [];
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

    test(
        'lookupAs returns the broker only when it implements the '
        'requested capability', () {
      // _StubBroker implements only AiBroker — not ChatBroker / EmbedBroker.
      AiBrokerRegistry.instance.register(_StubBroker('stub', 'Stub'));
      expect(
        AiBrokerRegistry.instance.lookupAs<AiBroker>('stub'),
        isNotNull,
        reason: 'every registered broker is at least an AiBroker',
      );
      expect(
        AiBrokerRegistry.instance.lookupAs<ChatBroker>('stub'),
        isNull,
        reason: '_StubBroker does not implement ChatBroker',
      );
      expect(
        AiBrokerRegistry.instance.lookupAs<EmbedBroker>('stub'),
        isNull,
        reason: '_StubBroker does not implement EmbedBroker',
      );
      expect(
        AiBrokerRegistry.instance.lookupAs<ChatBroker>('missing-id'),
        isNull,
        reason: 'unknown ids return null regardless of type',
      );
    });
  });

  group('capability declarations', () {
    // Trip-wire: if a provider class changes which capabilities it
    // implements, these tests fail loudly. Pairs with the per-broker
    // tests in test/brokers/.
    test('OpenAiBroker implements ChatBroker + EmbedBroker', () {
      final b = OpenAiBroker();
      expect(b, isA<ChatBroker>());
      expect(b, isA<EmbedBroker>());
    });

    test('AnthropicBroker implements ChatBroker only (no embed)', () {
      final b = AnthropicBroker();
      expect(b, isA<ChatBroker>());
      expect(b, isNot(isA<EmbedBroker>()));
    });

    test(
        'GoogleTranslateBroker implements TranslateBroker only '
        '(no chat / embed)', () {
      final b = GoogleTranslateBroker();
      expect(b, isA<TranslateBroker>());
      expect(b, isNot(isA<ChatBroker>()));
      expect(b, isNot(isA<EmbedBroker>()));
    });

    test('GeminiBroker implements ChatBroker + EmbedBroker', () {
      final b = GeminiBroker();
      expect(b, isA<ChatBroker>());
      expect(b, isA<EmbedBroker>());
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
