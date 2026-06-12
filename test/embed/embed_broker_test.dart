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

/// Smallest possible concrete [EmbedBroker]. Lets us assert the
/// interface contract without depending on any of the shipped
/// provider classes — exercises the type system shape (every
/// implementer is also an [AiBroker]) and the embed signature.
class _MinimalEmbed implements EmbedBroker {
  @override
  String get id => 'minimal';
  @override
  String get label => 'Minimal';
  @override
  Future<List<String>> listModels(String apiKey) async => const [];
  @override
  Future<List<List<double>>> embed({
    required String apiKey,
    required String model,
    required List<String> inputs,
  }) async =>
      [
        for (final s in inputs) [s.length.toDouble()],
      ];
}

void main() {
  group('EmbedBroker contract', () {
    test('every EmbedBroker is also an AiBroker', () {
      final b = _MinimalEmbed();
      expect(b, isA<EmbedBroker>());
      expect(b, isA<AiBroker>());
    });

    test('is NOT automatically a ChatBroker — capabilities are independent',
        () {
      expect(_MinimalEmbed(), isNot(isA<ChatBroker>()));
    });

    test('embed returns one vector per input in the same order', () async {
      final b = _MinimalEmbed();
      final out = await b.embed(
        apiKey: 'k',
        model: 'm',
        inputs: const ['a', 'bb', 'ccc'],
      );
      expect(out, hasLength(3));
      expect(out[0].single, 1.0);
      expect(out[1].single, 2.0);
      expect(out[2].single, 3.0);
    });
  });
}
