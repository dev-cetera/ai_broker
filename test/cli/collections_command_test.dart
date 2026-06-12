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

import 'dart:io';
import 'dart:typed_data';

import 'package:ai_broker/ai_broker.dart';
import 'package:test/test.dart';

void main() {
  group('CollectionsCommand', () {
    late Directory tmp;
    late String dbPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('aib_cols_test_');
      dbPath = '${tmp.path}/corpus.db';
      // Bypass the ingest pipeline — collections is a read-only probe,
      // so we set up a minimal `demo` collection directly via the
      // store API. No broker / API key needed.
      final store = CorpusStore.openOrCreate(dbPath);
      try {
        store.upsertCollection(
          name: 'demo',
          embedBroker: 'openai',
          embedModel: 'text-embedding-3-small',
          dim: 3,
        );
        store.addDocument(
          collection: 'demo',
          sourcePath: 'a.txt',
          contentHash: 'h',
          chunks: const [
            TextChunk(text: 'hi', sourcePath: 'a.txt', ord: 0),
          ],
          vectors: [
            Float32List.fromList([1, 0, 0]),
          ],
        );
      } finally {
        store.close();
      }
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('--exists returns 0 for a present collection', () async {
      final code = await buildAibRunner().run([
        'collections',
        '--db',
        dbPath,
        '--exists',
        'demo',
      ]);
      expect(code, 0);
    });

    test('--exists returns 1 for a missing collection', () async {
      final code = await buildAibRunner().run([
        'collections',
        '--db',
        dbPath,
        '--exists',
        'nope',
      ]);
      expect(code, 1);
    });

    test('--exists returns 1 when the db file is absent', () async {
      final code = await buildAibRunner().run([
        'collections',
        '--db',
        '${tmp.path}/missing.db',
        '--exists',
        'anything',
      ]);
      expect(code, 1);
    });

    test('plain `collections` lists every pinned collection', () async {
      // We can't easily capture stdout here, but exit 0 + no throw
      // exercises the happy path; structured output is verified by
      // looking at the human-readable column order in CorpusStore tests.
      final code = await buildAibRunner().run([
        'collections',
        '--db',
        dbPath,
      ]);
      expect(code, 0);
    });
  });
}
