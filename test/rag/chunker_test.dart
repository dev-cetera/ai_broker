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
  group('SentenceWindowChunker', () {
    test('empty input produces no chunks', () {
      const c = SentenceWindowChunker();
      expect(c.chunk('', sourcePath: 'x.txt'), isEmpty);
      expect(c.chunk('   \n\n  ', sourcePath: 'x.txt'), isEmpty);
    });

    test('short text fits in a single chunk', () {
      const c = SentenceWindowChunker(targetChars: 200, overlapChars: 20);
      final out = c.chunk(
        'First sentence. Second sentence. Third one.',
        sourcePath: 'a.txt',
      );
      expect(out, hasLength(1));
      expect(
        out.single.text,
        'First sentence. Second sentence. Third one.',
      );
      expect(out.single.sourcePath, 'a.txt');
      expect(out.single.ord, 0);
    });

    test('rolls over to a second chunk when target is exceeded', () {
      const c = SentenceWindowChunker(targetChars: 60, overlapChars: 15);
      // Each sentence ~25 chars; 3 sentences ~ 75 chars > 60.
      final out = c.chunk(
        'The fox jumps over a small log. '
        'It then trots across the field. '
        'Finally it pauses by the river.',
        sourcePath: 'b.txt',
      );
      expect(out.length, greaterThanOrEqualTo(2));
      // Ordinals are 0-based and contiguous.
      for (var i = 0; i < out.length; i++) {
        expect(out[i].ord, i);
      }
      // Adjacent chunks share at least a word of overlap.
      final firstTail = out[0].text.split(RegExp(r'\s+')).last;
      expect(out[1].text.toLowerCase(), contains(firstTail.toLowerCase()));
    });

    test('a single sentence longer than the target is hard-split', () {
      const c = SentenceWindowChunker(targetChars: 50, overlapChars: 0);
      final long = 'a' * 200;
      final out = c.chunk('$long.', sourcePath: 'c.txt');
      expect(out.length, greaterThanOrEqualTo(4));
      for (final chunk in out) {
        expect(chunk.text.length, lessThanOrEqualTo(50));
      }
    });

    test(
        'no chunk exceeds targetChars + overlapChars (regression: flush '
        'must clear the buffer)', () {
      const targetChars = 200;
      const overlapChars = 40;
      const c = SentenceWindowChunker(
        targetChars: targetChars,
        overlapChars: overlapChars,
      );

      // 30 short sentences. With a bug where `flush()` doesn't clear
      // the buffer, chunks accumulate forever and the last chunks blow
      // past targetChars by orders of magnitude.
      final body = List.generate(
        30,
        (i) => 'Sentence number $i has roughly thirty characters here.',
      ).join(' ');

      final out = c.chunk(body, sourcePath: 'long.txt');
      expect(out, isNotEmpty);
      // Hard bound: every chunk fits in the worst-case envelope of one
      // sentence (≤ targetChars) plus the overlap tail.
      const maxAllowed = targetChars + overlapChars + 2; // +2 for spaces
      for (final chunk in out) {
        expect(
          chunk.text.length,
          lessThanOrEqualTo(maxAllowed),
          reason: 'chunk #${chunk.ord} grew to ${chunk.text.length} chars '
              '— buffer carryover bug?',
        );
      }
    });

    test('metadata is propagated to every chunk', () {
      const c = SentenceWindowChunker(targetChars: 40, overlapChars: 5);
      final out = c.chunk(
        'One sentence. Another sentence. A third sentence here.',
        sourcePath: 'd.txt',
        meta: const {'chapter': 3},
      );
      expect(out, isNotEmpty);
      for (final chunk in out) {
        expect(chunk.meta, {'chapter': 3});
        expect(chunk.sourcePath, 'd.txt');
      }
    });
  });
}
