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

void main() {
  group('MapKeyResolver', () {
    test('resolve returns the key when present', () async {
      final r = MapKeyResolver({'openai': 'sk-abc'});
      expect(await r.resolve('openai'), 'sk-abc');
    });

    test('resolve returns null when the broker id is missing', () async {
      final r = MapKeyResolver({'openai': 'sk-abc'});
      expect(await r.resolve('anthropic'), isNull);
    });

    test('require returns the key when present', () async {
      final r = MapKeyResolver({'gemini': 'g-key'});
      expect(await r.require('gemini'), 'g-key');
    });

    test('require throws MissingKeyException for a missing key', () async {
      final r = MapKeyResolver({'openai': 'sk-abc'});
      await expectLater(
        r.require('anthropic'),
        throwsA(isA<MissingKeyException>()),
      );
    });

    test('require throws MissingKeyException for an empty key', () async {
      final r = MapKeyResolver({'openai': ''});
      await expectLater(
        r.require('openai'),
        throwsA(isA<MissingKeyException>()),
      );
    });
  });

  group('EnvKeyResolver', () {
    test('defaults populate openai / anthropic / gemini env var names', () {
      final r = EnvKeyResolver();
      expect(r.envVarNames['openai'], 'OPENAI_API_KEY');
      expect(r.envVarNames['anthropic'], 'ANTHROPIC_API_KEY');
      expect(r.envVarNames['gemini'], 'GEMINI_API_KEY');
    });

    test('overrides win over defaults', () {
      final r = EnvKeyResolver(overrides: {'gemini': 'GOOGLE_API_KEY'});
      expect(r.envVarNames['gemini'], 'GOOGLE_API_KEY');
      expect(r.envVarNames['openai'], 'OPENAI_API_KEY');
    });

    test('overrides can introduce new broker ids', () {
      final r = EnvKeyResolver(overrides: {'custom': 'CUSTOM_KEY'});
      expect(r.envVarNames['custom'], 'CUSTOM_KEY');
    });

    test('resolve returns null for an unmapped broker id', () async {
      final r = EnvKeyResolver();
      expect(await r.resolve('not-a-real-broker'), isNull);
    });
  });

  group('MissingKeyException', () {
    test('toString mentions the broker id', () {
      const e = MissingKeyException('openai');
      expect(e.toString(), contains('openai'));
      expect(e.toString(), startsWith('MissingKeyException'));
    });

    test('is an Exception', () {
      expect(const MissingKeyException('x'), isA<Exception>());
    });
  });
}
