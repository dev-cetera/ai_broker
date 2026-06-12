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

/// Splits a source document into [TextChunk]s suitable for embedding.
abstract class Chunker {
  List<TextChunk> chunk(
    String text, {
    required String sourcePath,
    Map<String, Object?> meta,
  });
}

/// Sentence-aware sliding window. Packs sentences greedily into windows
/// of approximately [targetChars] characters with [overlapChars] of
/// trailing context carried forward into the next window.
///
/// Sizes are in **characters**, not tokens — Dart has no native
/// tokenizer for the OpenAI / Gemini embedding models. Use ~4 chars per
/// token as a rule of thumb (so 3200 chars ≈ 800 tokens, well under the
/// 8191-token per-input limit on `text-embedding-3-*`).
///
/// Sentence detection is intentionally simple: split on `.`, `!`, `?`
/// followed by whitespace. Edge cases like "Mr. Smith" produce slightly
/// finer-grained chunks, which is harmless — the boundary doesn't
/// affect retrieval quality at this resolution.
class SentenceWindowChunker implements Chunker {
  final int targetChars;
  final int overlapChars;

  const SentenceWindowChunker({
    this.targetChars = 3200,
    this.overlapChars = 600,
  })  : assert(targetChars > 0),
        assert(overlapChars >= 0),
        assert(overlapChars < targetChars);

  static final _sentenceEnd = RegExp(r'(?<=[.!?])\s+');

  @override
  List<TextChunk> chunk(
    String text, {
    required String sourcePath,
    Map<String, Object?> meta = const {},
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];

    final sentences = _splitSentences(trimmed);
    final chunks = <TextChunk>[];
    final buf = StringBuffer();
    var ord = 0;

    void flush() {
      final body = buf.toString().trim();
      buf.clear();
      if (body.isEmpty) return;
      chunks.add(
        TextChunk(text: body, sourcePath: sourcePath, ord: ord, meta: meta),
      );
      ord++;
    }

    for (final sentence in sentences) {
      // If a single sentence is longer than the target, hard-split it on
      // whitespace so we never produce chunks above the per-input ceiling.
      if (sentence.length > targetChars) {
        flush();
        final pieces = _hardSplit(sentence, targetChars);
        for (final p in pieces) {
          chunks.add(
            TextChunk(text: p, sourcePath: sourcePath, ord: ord, meta: meta),
          );
          ord++;
        }
        continue;
      }

      if (buf.length + sentence.length + 1 > targetChars && buf.isNotEmpty) {
        // Carry the tail of the current buffer forward as overlap so
        // adjacent chunks share context. Snap to a sentence boundary
        // inside the tail when possible.
        final tail = _takeOverlap(buf.toString(), overlapChars);
        flush();
        buf.write(tail);
        if (buf.isNotEmpty && !buf.toString().endsWith(' ')) buf.write(' ');
      }

      buf.write(sentence);
      buf.write(' ');
    }
    flush();
    return chunks;
  }

  List<String> _splitSentences(String text) {
    final parts = text.split(_sentenceEnd);
    return parts.where((p) => p.trim().isNotEmpty).toList(growable: false);
  }

  /// Pulls the last [n] chars of [s], snapping forward to the next
  /// whitespace boundary so we don't slice mid-word.
  String _takeOverlap(String s, int n) {
    if (n <= 0 || s.length <= n) return s;
    final start = s.length - n;
    var i = start;
    while (i < s.length && s[i] != ' ' && s[i] != '\n') {
      i++;
    }
    if (i >= s.length) return s.substring(start);
    return s.substring(i + 1);
  }

  List<String> _hardSplit(String s, int size) {
    final out = <String>[];
    var i = 0;
    while (i < s.length) {
      var end = (i + size).clamp(0, s.length);
      // Don't split a UTF-16 surrogate pair. If we'd land between a
      // high (0xD800–0xDBFF) and low (0xDC00–0xDFFF) surrogate, pull
      // back one code unit so both halves stay together.
      if (end < s.length && end > i) {
        final prev = s.codeUnitAt(end - 1);
        final next = s.codeUnitAt(end);
        if (prev >= 0xD800 &&
            prev <= 0xDBFF &&
            next >= 0xDC00 &&
            next <= 0xDFFF) {
          end -= 1;
        }
      }
      // Guard: if the surrogate pull-back collapsed end to i (only
      // possible when `size == 1` and the input starts on a high
      // surrogate), force at least one code unit of progress. Splitting
      // a pair in this pathological case beats spinning forever.
      if (end <= i) end = i + 1;
      out.add(s.substring(i, end));
      i = end;
    }
    return out;
  }
}
