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

import 'package:ai_broker/ai_broker.dart';
import 'package:test/test.dart';

/// Deterministic broker for end-to-end CLI tests. Doesn't hit the
/// network; produces a stable 4-d vector per input.
class _FakeBroker implements EmbedBroker {
  var calls = 0;
  var totalInputs = 0;

  @override
  String get id =>
      'openai'; // pretend to be openai so EnvKeyResolver path matches

  @override
  String get label => 'Fake';

  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  @override
  Future<List<List<double>>> embed({
    required String apiKey,
    required String model,
    required List<String> inputs,
  }) async {
    calls++;
    totalInputs += inputs.length;
    // 4-d toy embedding so tests stay legible.
    return [
      for (final s in inputs) [s.length.toDouble(), 0, 0, 0],
    ];
  }
}

void main() {
  group('IngestCommand end-to-end', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('aib_ingest_test_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('ingests a directory of .txt files and stores their chunks', () async {
      // Two files, each short enough to fit in one chunk with default settings.
      File('${tmp.path}/a.txt').writeAsStringSync(
        'The capital of France is Paris. It sits on the Seine.',
      );
      File('${tmp.path}/b.md').writeAsStringSync(
        '# Heading\n\nMarkdown is read as plain text for now.',
      );
      File('${tmp.path}/ignore.bin').writeAsStringSync('binary');

      final fake = _FakeBroker();
      final dbPath = '${tmp.path}/corpus.db';

      final runner = buildAibRunner(
        brokerFactory: (_) => fake,
        keyResolver: MapKeyResolver({'openai': 'sk-test'}),
      );

      final code = await runner.run([
        'ingest',
        '--collection',
        'tutorial',
        '--db',
        dbPath,
        tmp.path,
      ]);

      expect(code, 0);
      // One probe call (first ingest) + one call per ingested file.
      expect(fake.calls, 3);

      final store = CorpusStore.openOrCreate(dbPath);
      try {
        final info = store.collection('tutorial')!;
        expect(info.embedBroker, 'openai');
        expect(info.dim, 4);
        // Two docs, one chunk each (defaults are large).
        expect(info.chunkCount, 2);
      } finally {
        store.close();
      }
    });

    test('re-ingest is idempotent — no new chunks, no probe', () async {
      File('${tmp.path}/a.txt').writeAsStringSync('Some text content.');

      final fake = _FakeBroker();
      final dbPath = '${tmp.path}/corpus.db';
      final keys = MapKeyResolver({'openai': 'sk-test'});

      Future<int> runIngest() async {
        final r = buildAibRunner(brokerFactory: (_) => fake, keyResolver: keys);
        return await r.run([
              'ingest',
              '--collection',
              'tutorial',
              '--db',
              dbPath,
              '${tmp.path}/a.txt',
            ]) ??
            0;
      }

      expect(await runIngest(), 0);
      final callsAfterFirst = fake.calls;

      // Second run: no probe (collection already pinned) and no embed
      // (document already present by hash) — so zero new calls.
      expect(await runIngest(), 0);
      expect(
        fake.calls,
        callsAfterFirst,
        reason: 'second run should make no embed calls when nothing changed',
      );

      final store = CorpusStore.openOrCreate(dbPath);
      try {
        expect(store.collection('tutorial')!.chunkCount, 1);
      } finally {
        store.close();
      }
    });

    test('rejects path with no .txt/.md files', () async {
      File('${tmp.path}/only.bin').writeAsStringSync('nope');
      final fake = _FakeBroker();
      final runner = buildAibRunner(
        brokerFactory: (_) => fake,
        keyResolver: MapKeyResolver({'openai': 'sk-test'}),
      );
      final code = await runner.run([
        'ingest',
        '--db',
        '${tmp.path}/corpus.db',
        tmp.path,
      ]);
      expect(code, 1);
      expect(fake.calls, 0);
    });
  });
}
