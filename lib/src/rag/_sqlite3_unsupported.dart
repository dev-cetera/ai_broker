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

// Stand-in for `package:sqlite3/sqlite3.dart` on platforms without
// `dart:ffi` (the web). `corpus_store.dart` imports this file there, so the
// package barrel compiles on web while `CorpusStore` stays native-only:
// opening a store throws [UnsupportedError]. Only the surface
// `corpus_store.dart` touches is declared. The leading underscore keeps
// this file out of the generated `_src.dart` barrel.

typedef Row = Map<String, Object?>;
typedef ResultSet = List<Row>;

enum OpenMode { readOnly, readWrite, readWriteCreate }

abstract interface class PreparedStatement {
  void execute([List<Object?> parameters = const []]);
  void dispose();
}

abstract interface class Database {
  int get lastInsertRowId;
  void execute(String sql, [List<Object?> parameters = const []]);
  ResultSet select(String sql, [List<Object?> parameters = const []]);
  PreparedStatement prepare(String sql);
  void dispose();
}

const sqlite3 = _UnsupportedSqlite3();

final class _UnsupportedSqlite3 {
  const _UnsupportedSqlite3();

  Database open(String filename, {OpenMode mode = OpenMode.readWriteCreate}) =>
      throw _unsupported();

  Database openInMemory() => throw _unsupported();

  static UnsupportedError _unsupported() => UnsupportedError(
        'CorpusStore needs native SQLite (dart:ffi), which is not available '
        'on this platform. The chat, embed and translate brokers work here; '
        'the RAG store does not.',
      );
}
