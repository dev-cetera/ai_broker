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

import 'dart:typed_data';

import 'package:ai_broker/ai_broker.dart';
import 'package:test/test.dart';

Float32List _v(List<double> xs) => Float32List.fromList(xs);

void main() {
  group('CorpusStore', () {
    late CorpusStore store;

    setUp(() {
      store = CorpusStore.openInMemory();
    });

    tearDown(() => store.close());

    group('upsertCollection', () {
      test('first call pins broker/model/dim and returns 0 chunks', () {
        final c = store.upsertCollection(
          name: 'docs',
          embedBroker: 'openai',
          embedModel: 'text-embedding-3-small',
          dim: 3,
        );
        expect(c.name, 'docs');
        expect(c.embedBroker, 'openai');
        expect(c.embedModel, 'text-embedding-3-small');
        expect(c.dim, 3);
        expect(c.chunkCount, 0);
      });

      test('second matching call is idempotent', () {
        store.upsertCollection(
          name: 'docs',
          embedBroker: 'openai',
          embedModel: 'text-embedding-3-small',
          dim: 3,
        );
        final again = store.upsertCollection(
          name: 'docs',
          embedBroker: 'openai',
          embedModel: 'text-embedding-3-small',
          dim: 3,
        );
        expect(again.name, 'docs');
        expect(store.collections, hasLength(1));
      });

      test('mismatched values throw StateError', () {
        store.upsertCollection(
          name: 'docs',
          embedBroker: 'openai',
          embedModel: 'text-embedding-3-small',
          dim: 3,
        );
        expect(
          () => store.upsertCollection(
            name: 'docs',
            embedBroker: 'gemini',
            embedModel: 'text-embedding-004',
            dim: 768,
          ),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('addDocument', () {
      setUp(() {
        store.upsertCollection(
          name: 'docs',
          embedBroker: 'openai',
          embedModel: 'text-embedding-3-small',
          dim: 3,
        );
      });

      test('inserts a new document and its chunks', () {
        final result = store.addDocument(
          collection: 'docs',
          sourcePath: 'a.txt',
          contentHash: 'h1',
          chunks: [
            const TextChunk(text: 'hello', sourcePath: 'a.txt', ord: 0),
            const TextChunk(text: 'world', sourcePath: 'a.txt', ord: 1),
          ],
          vectors: [
            _v([1, 0, 0]),
            _v([0, 1, 0]),
          ],
        );
        expect(result.inserted, isTrue);
        expect(result.documentId, isNonZero);
        final info = store.collection('docs')!;
        expect(info.chunkCount, 2);
      });

      test('re-ingesting the same content is a no-op', () {
        for (var i = 0; i < 2; i++) {
          store.addDocument(
            collection: 'docs',
            sourcePath: 'a.txt',
            contentHash: 'h1',
            chunks: [
              const TextChunk(text: 'hello', sourcePath: 'a.txt', ord: 0),
            ],
            vectors: [
              _v([1, 0, 0]),
            ],
          );
        }
        expect(store.collection('docs')!.chunkCount, 1);
      });

      test('throws when chunk and vector counts disagree', () {
        expect(
          () => store.addDocument(
            collection: 'docs',
            sourcePath: 'a.txt',
            contentHash: 'h1',
            chunks: [
              const TextChunk(text: 'x', sourcePath: 'a.txt', ord: 0),
            ],
            vectors: [
              _v([1, 0, 0]),
              _v([0, 1, 0]),
            ],
          ),
          throwsArgumentError,
        );
      });

      test('throws when vector dim does not match the collection', () {
        expect(
          () => store.addDocument(
            collection: 'docs',
            sourcePath: 'a.txt',
            contentHash: 'h1',
            chunks: [
              const TextChunk(text: 'x', sourcePath: 'a.txt', ord: 0),
            ],
            vectors: [
              _v([1, 0]),
            ], // dim 2, collection is dim 3
          ),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('search', () {
      setUp(() {
        store.upsertCollection(
          name: 'docs',
          embedBroker: 'openai',
          embedModel: 'm',
          dim: 3,
        );
        store.addDocument(
          collection: 'docs',
          sourcePath: 'a.txt',
          contentHash: 'h',
          chunks: const [
            TextChunk(text: 'apple', sourcePath: 'a.txt', ord: 0),
            TextChunk(text: 'banana', sourcePath: 'a.txt', ord: 1),
            TextChunk(text: 'cherry', sourcePath: 'a.txt', ord: 2),
          ],
          vectors: [
            _v([1, 0, 0]),
            _v([0, 1, 0]),
            _v([0, 0, 1]),
          ],
        );
      });

      test('returns top-K ordered by cosine similarity', () {
        final hits = store.search(
          collection: 'docs',
          queryVector: _v([0.9, 0.1, 0]),
          topK: 2,
        );
        expect(hits, hasLength(2));
        expect(hits[0].chunk.text, 'apple');
        expect(hits[1].chunk.text, 'banana');
        expect(hits[0].score, greaterThan(hits[1].score));
      });

      test('empty collection name returns empty', () {
        expect(
          store.search(
            collection: 'missing',
            queryVector: _v([1, 0, 0]),
          ),
          isEmpty,
        );
      });

      test('dim mismatch throws ArgumentError', () {
        expect(
          () => store.search(
            collection: 'docs',
            queryVector: _v([1, 0]),
          ),
          throwsArgumentError,
        );
      });
    });
  });
}
