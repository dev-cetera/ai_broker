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
  group('TranslationResult', () {
    test('stores translated text plus optional detectedFrom / modelUsed', () {
      const r = TranslationResult(
        translated: 'bonjour',
        detectedFrom: 'en',
        modelUsed: 'gpt-4o-mini',
      );
      expect(r.translated, 'bonjour');
      expect(r.detectedFrom, 'en');
      expect(r.modelUsed, 'gpt-4o-mini');
    });

    test('detectedFrom and modelUsed default to null', () {
      const r = TranslationResult(translated: 'x');
      expect(r.detectedFrom, isNull);
      expect(r.modelUsed, isNull);
    });

    test('toString surfaces all three fields', () {
      const r = TranslationResult(
        translated: 'hola',
        detectedFrom: 'en',
        modelUsed: 'llm',
      );
      final s = r.toString();
      expect(s, contains('hola'));
      expect(s, contains('en'));
      expect(s, contains('llm'));
    });
  });
}
