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

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '/_common.dart';

/// SQLite-backed store for chunked text + embeddings.
///
/// Schema lives in three tables: `collections` (pins embed model per
/// collection), `documents` (one row per ingested source file), and
/// `chunks` (text + embedding BLOB, FK to document). The same schema is
/// used for the workbench DB and for portable bundles — a bundle is just
/// a SQLite file containing one collection's rows plus a `bundle_meta`
/// table with the manifest.
///
/// Vectors are stored as little-endian-ish [Float32List] BLOBs. Search
/// is an in-memory cosine top-K over the collection's chunks; scales to
/// ~100k chunks comfortably on a laptop. Larger corpora should move to
/// `sqlite-vec` (drop-in BLOB-compatible).
class CorpusStore {
  final Database _db;
  final bool _readOnly;
  CorpusStore._(this._db, this._readOnly);

  /// Opens or creates a SQLite file at [path]. With [readOnly] true, the
  /// file must already exist and the schema is left untouched — used for
  /// shipped bundles.
  static CorpusStore openOrCreate(String path, {bool readOnly = false}) {
    final db = sqlite3.open(
      path,
      mode: readOnly ? OpenMode.readOnly : OpenMode.readWriteCreate,
    );
    if (!readOnly) {
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA foreign_keys = ON;');
      _ensureSchema(db);
    }
    return CorpusStore._(db, readOnly);
  }

  /// Opens an in-memory store. Used by tests so they don't touch disk.
  @visibleForTesting
  static CorpusStore openInMemory() {
    final db = sqlite3.openInMemory();
    db.execute('PRAGMA foreign_keys = ON;');
    _ensureSchema(db);
    return CorpusStore._(db, false);
  }

  bool get isReadOnly => _readOnly;

  void close() => _db.dispose();

  static void _ensureSchema(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS collections (
        name TEXT PRIMARY KEY,
        embed_broker TEXT NOT NULL,
        embed_model TEXT NOT NULL,
        dim INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS documents (
        id INTEGER PRIMARY KEY,
        collection TEXT NOT NULL REFERENCES collections(name),
        source_path TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        ingested_at INTEGER NOT NULL,
        UNIQUE(collection, source_path, content_hash)
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS documents_collection '
      'ON documents(collection);',
    );
    db.execute('''
      CREATE TABLE IF NOT EXISTS chunks (
        id INTEGER PRIMARY KEY,
        document_id INTEGER NOT NULL
          REFERENCES documents(id) ON DELETE CASCADE,
        ord INTEGER NOT NULL,
        text TEXT NOT NULL,
        embedding BLOB NOT NULL,
        meta TEXT
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS chunks_document ON chunks(document_id);',
    );
  }

  /// Pins (or returns) a collection. First call fixes the embed
  /// broker/model/dim; subsequent calls with matching values are no-ops,
  /// mismatched values throw [StateError].
  CollectionInfo upsertCollection({
    required String name,
    required String embedBroker,
    required String embedModel,
    required int dim,
  }) {
    final existing = collection(name);
    if (existing != null) {
      if (existing.embedBroker != embedBroker ||
          existing.embedModel != embedModel ||
          existing.dim != dim) {
        throw StateError(
          'Collection "$name" is pinned to '
          '${existing.embedBroker}/${existing.embedModel} '
          '(dim ${existing.dim}); tried to use '
          '$embedBroker/$embedModel (dim $dim). '
          'Create a different collection or delete this one.',
        );
      }
      return existing;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO collections(name, embed_broker, embed_model, dim, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [name, embedBroker, embedModel, dim, now],
    );
    return CollectionInfo(
      name: name,
      embedBroker: embedBroker,
      embedModel: embedModel,
      dim: dim,
      chunkCount: 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(now),
    );
  }

  /// Whether a document with this `(collection, source_path,
  /// content_hash)` already exists. Use this to skip embedding work on
  /// re-ingest — [addDocument] is idempotent too, but you'll have paid
  /// the embed call by the time it deduplicates.
  bool hasDocument({
    required String collection,
    required String sourcePath,
    required String contentHash,
  }) {
    final r = _db.select(
      'SELECT 1 FROM documents '
      'WHERE collection=? AND source_path=? AND content_hash=? LIMIT 1',
      [collection, sourcePath, contentHash],
    );
    return r.isNotEmpty;
  }

  /// Adds a document with its chunks + vectors atomically. Idempotent on
  /// (collection, source_path, content_hash) — re-ingesting the same
  /// content returns the existing document id without duplicating rows.
  ///
  /// Returns `(documentId, inserted)` — `inserted` is false when the
  /// document was already present.
  ({int documentId, bool inserted}) addDocument({
    required String collection,
    required String sourcePath,
    required String contentHash,
    required List<TextChunk> chunks,
    required List<Float32List> vectors,
  }) {
    if (chunks.length != vectors.length) {
      throw ArgumentError(
        'chunks.length (${chunks.length}) != vectors.length '
        '(${vectors.length})',
      );
    }
    final info = this.collection(collection);
    if (info == null) {
      throw StateError(
        'Collection "$collection" not pinned. Call upsertCollection first.',
      );
    }

    _db.execute('BEGIN');
    try {
      final existing = _db.select(
        'SELECT id FROM documents '
        'WHERE collection=? AND source_path=? AND content_hash=?',
        [collection, sourcePath, contentHash],
      );
      if (existing.isNotEmpty) {
        _db.execute('COMMIT');
        return (
          documentId: existing.first['id'] as int,
          inserted: false,
        );
      }

      _db.execute(
        'INSERT INTO documents(collection, source_path, content_hash, ingested_at) '
        'VALUES (?, ?, ?, ?)',
        [
          collection,
          sourcePath,
          contentHash,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      final docId = _db.lastInsertRowId;

      final stmt = _db.prepare(
        'INSERT INTO chunks(document_id, ord, text, embedding, meta) '
        'VALUES (?, ?, ?, ?, ?)',
      );
      try {
        for (var i = 0; i < chunks.length; i++) {
          final c = chunks[i];
          final v = vectors[i];
          if (v.length != info.dim) {
            throw StateError(
              'Vector dim ${v.length} != collection dim ${info.dim}',
            );
          }
          stmt.execute([
            docId,
            c.ord,
            c.text,
            _floatToBytes(v),
            c.meta.isEmpty ? null : jsonEncode(c.meta),
          ]);
        }
      } finally {
        stmt.dispose();
      }
      _db.execute('COMMIT');
      return (documentId: docId, inserted: true);
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Cosine top-K search within [collection]. Empty list if the
  /// collection doesn't exist; throws [ArgumentError] on dim mismatch.
  List<Hit> search({
    required String collection,
    required Float32List queryVector,
    int topK = 8,
  }) {
    final info = this.collection(collection);
    if (info == null) return const [];
    if (queryVector.length != info.dim) {
      throw ArgumentError(
        'Query dim ${queryVector.length} != collection dim ${info.dim}',
      );
    }
    final qNorm = _norm(queryVector);
    if (qNorm == 0) return const [];

    final rows = _db.select(
      'SELECT c.ord, c.text, c.embedding, c.meta, d.source_path '
      'FROM chunks c '
      'JOIN documents d ON c.document_id = d.id '
      'WHERE d.collection = ?',
      [collection],
    );

    final scored = <_Scored>[];
    for (final row in rows) {
      final vec = _bytesToFloat(row['embedding'] as Uint8List);
      final norm = _norm(vec);
      if (norm == 0) continue;
      final score = _dot(queryVector, vec) / (qNorm * norm);
      scored.add(_Scored(score: score, row: row));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final hits = <Hit>[];
    for (final s in scored.take(topK)) {
      final r = s.row;
      final metaJson = r['meta'] as String?;
      final meta = metaJson == null
          ? const <String, Object?>{}
          : (jsonDecode(metaJson) as Map<String, Object?>);
      hits.add(
        Hit(
          chunk: TextChunk(
            text: r['text'] as String,
            sourcePath: r['source_path'] as String,
            ord: r['ord'] as int,
            meta: meta,
          ),
          score: s.score,
        ),
      );
    }
    return hits;
  }

  /// Fetches one collection's pin + chunk count. Null if not present.
  CollectionInfo? collection(String name) {
    final r = _db.select(
      'SELECT c.name, c.embed_broker, c.embed_model, c.dim, c.created_at, '
      '  (SELECT COUNT(*) FROM chunks ch '
      '   JOIN documents d ON ch.document_id = d.id '
      '   WHERE d.collection = c.name) AS chunk_count '
      'FROM collections c WHERE c.name = ?',
      [name],
    );
    if (r.isEmpty) return null;
    return _rowToCollection(r.first);
  }

  /// All pinned collections with their counts.
  List<CollectionInfo> get collections {
    final r = _db.select(
      'SELECT c.name, c.embed_broker, c.embed_model, c.dim, c.created_at, '
      '  (SELECT COUNT(*) FROM chunks ch '
      '   JOIN documents d ON ch.document_id = d.id '
      '   WHERE d.collection = c.name) AS chunk_count '
      'FROM collections c ORDER BY c.name',
    );
    return r.map(_rowToCollection).toList(growable: false);
  }

  CollectionInfo _rowToCollection(Row r) => CollectionInfo(
        name: r['name'] as String,
        embedBroker: r['embed_broker'] as String,
        embedModel: r['embed_model'] as String,
        dim: r['dim'] as int,
        chunkCount: r['chunk_count'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );

  // ── vector helpers ─────────────────────────────────────────────────

  static Uint8List _floatToBytes(Float32List v) =>
      // Copy: the Float32List may live in a pool reused after this call
      // returns. sqlite3 binds bytes synchronously, so a view would be
      // safe today, but the read path copies too — keep it symmetric.
      Uint8List.fromList(
        v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes),
      );

  static Float32List _bytesToFloat(Uint8List b) {
    // Copy: the underlying buffer is owned by sqlite3 and may be reused
    // between rows. Float32List.view on a shared buffer is a footgun.
    final copy = Uint8List.fromList(b);
    return copy.buffer.asFloat32List();
  }

  static double _dot(Float32List a, Float32List b) {
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  static double _norm(Float32List v) {
    var s = 0.0;
    for (var i = 0; i < v.length; i++) {
      s += v[i] * v[i];
    }
    return math.sqrt(s);
  }
}

class _Scored {
  final double score;
  final Row row;
  _Scored({required this.score, required this.row});
}

/// One retrieval result. [score] is cosine similarity in `[-1, 1]`,
/// higher is better.
@immutable
class Hit {
  final TextChunk chunk;
  final double score;
  const Hit({required this.chunk, required this.score});
}

/// Read-only snapshot of a collection's pin + counts.
@immutable
class CollectionInfo {
  final String name;
  final String embedBroker;
  final String embedModel;
  final int dim;
  final int chunkCount;
  final DateTime createdAt;
  const CollectionInfo({
    required this.name,
    required this.embedBroker,
    required this.embedModel,
    required this.dim,
    required this.chunkCount,
    required this.createdAt,
  });
}
