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

import 'dart:async';

import 'package:ai_broker/ai_broker.dart';
import 'package:test/test.dart';

/// Hands whatever has arrived to the listener before the test looks at it.
/// A few event-loop turns, not one: the wrapper sits behind an async
/// generator, so a single microtask drain isn't enough.
Future<void> _pump() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('StreamedCompletion.fromDeltas', () {
    test('forwards every delta and completes with the joined text', () async {
      final turn = StreamedCompletion.fromDeltas(
        deltas: Stream<String>.fromIterable(['  hi', ' there  ']),
        model: 'm',
      );
      expect(await turn.deltas.toList(), ['  hi', ' there  ']);
      final done = await turn.completion;
      // Trimmed, so a streamed turn and `chat()` agree on the final string.
      expect(done.text, 'hi there');
      expect(done.model, 'm');
      expect(done.stopReason, AiStopReason.endTurn);
      expect(done.inputTokens, 0);
      expect(done.outputTokens, 0);
    });

    test('does not touch the source until the deltas are listened to',
        () async {
      var subscribed = false;
      Stream<String> source() async* {
        subscribed = true;
        yield 'x';
      }

      final turn = StreamedCompletion.fromDeltas(
        deltas: source(),
        model: 'm',
      );
      await _pump();
      expect(subscribed, isFalse, reason: 'nothing should be sent yet');
      await turn.deltas.toList();
      expect(subscribed, isTrue);
    });

    test('a failure reaches both the deltas and the completion', () async {
      final turn = StreamedCompletion.fromDeltas(
        deltas: Stream<String>.error(const AiBrokerException('boom')),
        model: 'm',
      );
      await expectLater(
        turn.deltas.toList(),
        throwsA(isA<AiBrokerException>()),
      );
      await expectLater(turn.completion, throwsA(isA<AiBrokerException>()));
    });

    test('an unread completion future does not raise an unhandled error',
        () async {
      // This is the `stream()` path: the caller only wants text, so nothing
      // ever awaits `completion`. That error must not escape the zone.
      final errors = <Object>[];
      await runZonedGuarded(
        () async {
          final turn = StreamedCompletion.fromDeltas(
            deltas: Stream<String>.error(const AiBrokerException('boom')),
            model: 'm',
          );
          await turn.deltas.toList().catchError((Object _) => <String>[]);
          await _pump();
        },
        (e, _) => errors.add(e),
      );
      expect(errors, isEmpty);
    });

    test('abandoning the stream still settles the completion', () async {
      final source = StreamController<String>();
      final turn = StreamedCompletion.fromDeltas(
        deltas: source.stream,
        model: 'm',
      );
      final seen = <String>[];
      final sub = turn.deltas.listen(seen.add);
      source.add('half ');
      await _pump();
      expect(seen, ['half ']);
      await sub.cancel();
      final done = await turn.completion;
      expect(done.text, 'half');
      await source.close();
    });

    test('carries a caller-supplied stop reason', () async {
      final turn = StreamedCompletion.fromDeltas(
        deltas: const Stream<String>.empty(),
        model: 'm',
        stopReason: AiStopReason.refusal,
      );
      await turn.deltas.toList();
      final done = await turn.completion;
      expect(done.isRefusal, isTrue);
      expect(done.text, isEmpty);
    });
  });
}
