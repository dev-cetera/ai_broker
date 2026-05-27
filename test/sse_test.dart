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

import 'dart:convert';

import 'package:ai_broker/ai_broker.dart';
import 'package:test/test.dart';

Stream<List<int>> _src(String text) =>
    Stream<List<int>>.fromIterable([utf8.encode(text)]);

Stream<List<int>> _chunked(List<String> chunks) =>
    Stream<List<int>>.fromIterable(chunks.map(utf8.encode));

void main() {
  group('decodeSseStream', () {
    test('emits a single event with data only', () async {
      final events = await decodeSseStream(_src('data: hello\n\n')).toList();
      expect(events, hasLength(1));
      expect(events.single.event, isNull);
      expect(events.single.data, 'hello');
    });

    test('captures the event name when present', () async {
      final events =
          await decodeSseStream(_src('event: ping\ndata: pong\n\n')).toList();
      expect(events.single.event, 'ping');
      expect(events.single.data, 'pong');
    });

    test('joins multi-line data with \\n per the SSE spec', () async {
      final events =
          await decodeSseStream(_src('data: line1\ndata: line2\n\n')).toList();
      expect(events.single.data, 'line1\nline2');
    });

    test('ignores SSE comments (lines starting with ":")', () async {
      final events = await decodeSseStream(
        _src(': keep-alive\ndata: ok\n\n'),
      ).toList();
      expect(events, hasLength(1));
      expect(events.single.data, 'ok');
    });

    test('splits multiple events by blank lines', () async {
      final events = await decodeSseStream(
        _src('data: one\n\ndata: two\n\ndata: three\n\n'),
      ).toList();
      expect(events.map((e) => e.data), ['one', 'two', 'three']);
    });

    test('strips exactly one leading space after "data:"', () async {
      final events =
          await decodeSseStream(_src('data:  two-spaces\n\n')).toList();
      expect(events.single.data, ' two-spaces');
    });

    test('flushes a trailing event when the source ends without a blank line',
        () async {
      final events = await decodeSseStream(_src('data: tail')).toList();
      expect(events.single.data, 'tail');
    });

    test('buffers across chunk boundaries', () async {
      // The header arrives in one chunk, the data over two chunks, and the
      // terminating blank line in a fourth — the decoder must stitch them.
      final events = await decodeSseStream(
        _chunked(['event: stream\ndata: hel', 'lo wor', 'ld\n', '\n']),
      ).toList();
      expect(events.single.event, 'stream');
      expect(events.single.data, 'hello world');
    });

    test('ignores unknown fields like id: and retry:', () async {
      final events = await decodeSseStream(
        _src('id: 42\nretry: 1000\ndata: keep\n\n'),
      ).toList();
      expect(events.single.data, 'keep');
    });

    test('emits nothing for an empty stream', () async {
      final events = await decodeSseStream(_src('')).toList();
      expect(events, isEmpty);
    });

    test('produces an event with empty data when only event: is set', () async {
      final events = await decodeSseStream(_src('event: ping\n\n')).toList();
      expect(events.single.event, 'ping');
      expect(events.single.data, '');
    });
  });
}
