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

/// One chunk of source text. Carries enough metadata to cite back to the
/// original document (source path + ordinal within that document) plus
/// arbitrary [meta] for higher-level info (page number, heading path,
/// etc.).
///
/// Chunks are produced by a [Chunker]; an [Embedder] turns the [text] of
/// each chunk into a vector; a `CorpusStore` persists the pair.
@immutable
class TextChunk {
  /// The chunk's text payload — what gets embedded and shown back to the
  /// model at retrieval time.
  final String text;

  /// Origin file (or logical identifier) for citations. Free-form; the
  /// store uses it verbatim.
  final String sourcePath;

  /// Index of this chunk within its source document, starting at 0.
  /// Adjacent ordinals share `overlap` characters when produced by a
  /// sliding-window chunker.
  final int ord;

  /// Free-form per-chunk metadata. Stored as JSON in the SQLite row.
  /// Keep values JSON-encodable (no DateTime, no custom types).
  final Map<String, Object?> meta;

  const TextChunk({
    required this.text,
    required this.sourcePath,
    required this.ord,
    this.meta = const {},
  });

  @override
  String toString() => 'TextChunk($sourcePath#$ord, ${text.length} chars)';
}
