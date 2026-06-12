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

class _RecordingBroker implements EmbedBroker {
  final List<List<String>> batches = [];

  @override
  String get id => 'fake';
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
    batches.add(List<String>.from(inputs));
    // Echo each input as a tiny 2-d vector so the test can verify
    // ordering across batches.
    return [
      for (var i = 0; i < inputs.length; i++)
        [i.toDouble(), inputs[i].length.toDouble()],
    ];
  }
}

void main() {
  group('Embedder', () {
    test('empty input returns empty without touching the broker', () async {
      final broker = _RecordingBroker();
      final e = Embedder(broker: broker, apiKey: 'k', model: 'm');
      expect(await e.embedAll(const []), isEmpty);
      expect(broker.batches, isEmpty);
    });

    test('single batch when inputs fit', () async {
      final broker = _RecordingBroker();
      final e =
          Embedder(broker: broker, apiKey: 'k', model: 'm', batchSize: 10);
      final out = await e.embedAll(['a', 'bb', 'ccc']);
      expect(broker.batches, [
        ['a', 'bb', 'ccc'],
      ]);
      expect(out, hasLength(3));
      expect(out[0].length, 2);
    });

    test('splits across batches and preserves order', () async {
      final broker = _RecordingBroker();
      final e = Embedder(broker: broker, apiKey: 'k', model: 'm', batchSize: 2);
      final inputs = ['a', 'b', 'c', 'd', 'e'];
      final out = await e.embedAll(inputs);
      expect(broker.batches, [
        ['a', 'b'],
        ['c', 'd'],
        ['e'],
      ]);
      expect(out, hasLength(5));
    });

    test('providerId mirrors the broker id', () {
      final broker = _RecordingBroker();
      final e = Embedder(broker: broker, apiKey: 'k', model: 'm');
      expect(e.providerId, 'fake');
    });

    test('splits a batch when charBudget is exceeded', () async {
      // Three inputs of 50 chars each; budget of 100 chars per call.
      // Expected: [a,b] (100 chars, at budget) then [c] (50 chars).
      final broker = _RecordingBroker();
      final e = Embedder(
        broker: broker,
        apiKey: 'k',
        model: 'm',
        batchSize: 100, // not the binding constraint here
        charBudget: 100,
      );
      final inputs = ['a' * 50, 'b' * 50, 'c' * 50];
      final out = await e.embedAll(inputs);
      expect(out, hasLength(3));
      expect(broker.batches, [
        ['a' * 50, 'b' * 50],
        ['c' * 50],
      ]);
    });

    test('always sends a batch of at least one even if it exceeds budget',
        () async {
      // Single input larger than charBudget — must still be sent (a batch
      // of one), so the provider returns its own clean error rather than
      // the embedder silently looping forever.
      final broker = _RecordingBroker();
      final e = Embedder(
        broker: broker,
        apiKey: 'k',
        model: 'm',
        batchSize: 100,
        charBudget: 10,
      );
      final out = await e.embedAll(['x' * 100]);
      expect(out, hasLength(1));
      expect(broker.batches, [
        ['x' * 100],
      ]);
    });
  });
}
