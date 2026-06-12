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
  group('TextChunk', () {
    test('stores all fields verbatim', () {
      const chunk = TextChunk(
        text: 'hello world',
        sourcePath: 'docs/intro.md',
        ord: 3,
        meta: {'page': 12, 'heading': 'Setup'},
      );
      expect(chunk.text, 'hello world');
      expect(chunk.sourcePath, 'docs/intro.md');
      expect(chunk.ord, 3);
      expect(chunk.meta, {'page': 12, 'heading': 'Setup'});
    });

    test('meta defaults to an empty map', () {
      const chunk = TextChunk(
        text: 't',
        sourcePath: 'p',
        ord: 0,
      );
      expect(chunk.meta, isEmpty);
    });

    test('toString includes path, ord, and char length', () {
      const chunk = TextChunk(
        text: '1234567890',
        sourcePath: 'a.txt',
        ord: 7,
      );
      final s = chunk.toString();
      expect(s, contains('a.txt'));
      expect(s, contains('#7'));
      expect(s, contains('10 chars'));
    });
  });
}
