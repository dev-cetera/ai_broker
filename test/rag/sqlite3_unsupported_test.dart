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

// The web stand-in for package:sqlite3. Imported directly here because on
// the VM the conditional import in corpus_store.dart picks real SQLite.
// ignore: implementation_imports
import 'package:ai_broker/src/rag/_sqlite3_unsupported.dart';
import 'package:test/test.dart';

void main() {
  test('opening a database throws UnsupportedError naming CorpusStore', () {
    expect(
      () => sqlite3.openInMemory(),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('CorpusStore'),
        ),
      ),
    );
    expect(
      () => sqlite3.open('x.db', mode: OpenMode.readOnly),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
