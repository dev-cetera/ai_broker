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

// The `abortTrigger` contract, for one broker per wire family (Anthropic,
// OpenAI-compatible, Gemini):
//
//  - the request goes out as an `Abortable` one carrying the trigger, so a
//    client that supports it closes the connection;
//  - completing the trigger mid-request fails the call with
//    `AiAbortedException`, even through a client that ignores the trigger;
//  - a trigger that already completed throws without sending anything;
//  - mid-stream, the deltas end with `AiAbortedException`, the response body
//    is cancelled and `completion` fails with the same exception;
//  - with the real `IOClient`, the socket is closed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_broker/ai_broker.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _request = ChatRequest(
  system: '',
  messages: [AiMessage.user('hi')],
);

/// One wire family: how to build its broker and what one streamed text
/// delta of `Hel` looks like on its wire.
class _Family {
  const _Family(this.name, this.build, this.sseEvent);

  final String name;
  final ChatBroker Function(Client client) build;
  final String sseEvent;
}

final _families = [
  _Family(
    'AnthropicBroker',
    (client) => AnthropicBroker(client: client),
    'event: content_block_delta\n'
        'data: {"type":"content_block_delta","index":0,'
        '"delta":{"type":"text_delta","text":"Hel"}}\n\n',
  ),
  _Family(
    'OpenAiCompatibleBroker',
    (client) => OpenAiCompatibleBroker(
      id: 'groq',
      label: 'Groq',
      baseUrl: 'https://api.groq.com/openai/v1',
      client: client,
    ),
    'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n',
  ),
  _Family(
    'GeminiBroker',
    (client) => GeminiBroker(client: client),
    'data: {"candidates":[{"content":{"parts":[{"text":"Hel"}]}}]}\n\n',
  ),
];

/// A client that receives the original request and never answers it, and
/// ignores the abort trigger — the worst case the broker has to cope with.
class _HangingClient {
  final requests = <BaseRequest>[];
  final sent = Completer<void>();

  late final client = MockClient.streaming((request, body) async {
    await body.drain<void>();
    requests.add(request);
    if (!sent.isCompleted) sent.complete();
    return Completer<StreamedResponse>().future;
  });
}

/// A client that answers 200 with a body the test writes to by hand.
class _StreamingClient {
  final body = StreamController<List<int>>();
  var bodyCancelled = false;
  var calls = 0;

  _StreamingClient() {
    body.onCancel = () => bodyCancelled = true;
  }

  late final client = MockClient.streaming((request, requestBody) async {
    await requestBody.drain<void>();
    calls++;
    return StreamedResponse(body.stream, 200);
  });
}

void main() {
  for (final family in _families) {
    group('${family.name} abortTrigger', () {
      test('chat: aborting mid-request throws AiAbortedException', () async {
        final fake = _HangingClient();
        final broker = family.build(fake.client);
        final trigger = Completer<void>();
        final call = broker.chat(
          apiKey: 'k',
          model: 'm',
          request: _request,
          abortTrigger: trigger.future,
        );
        await fake.sent.future;
        trigger.complete();
        await expectLater(call, throwsA(isA<AiAbortedException>()));
        // Sent as an abortable request carrying the caller's trigger, so a
        // client that supports it closes the connection.
        final sent = fake.requests.single;
        expect(sent, isA<Abortable>());
        expect((sent as Abortable).abortTrigger, same(trigger.future));
        expect(fake.requests, hasLength(1));
      });

      test('complete: a trigger that already completed sends nothing',
          () async {
        var called = false;
        final broker = family.build(
          MockClient((_) async {
            called = true;
            return Response('{}', 200);
          }),
        );
        await expectLater(
          broker.complete(
            apiKey: 'k',
            model: 'm',
            system: '',
            user: 'hi',
            abortTrigger: Future<void>.value(),
          ),
          throwsA(isA<AiAbortedException>()),
        );
        expect(called, isFalse);
      });

      test('a client that honours the trigger is reported the same way',
          () async {
        final broker = family.build(
          MockClient.streaming((request, body) async {
            await body.drain<void>();
            await (request as Abortable).abortTrigger;
            throw RequestAbortedException(request.url);
          }),
        );
        final trigger = Completer<void>();
        final call = broker.chatWithMeta(
          apiKey: 'k',
          model: 'm',
          request: _request,
          abortTrigger: trigger.future,
        );
        trigger.complete();
        await expectLater(call, throwsA(isA<AiAbortedException>()));
      });

      test('without a trigger the request is a plain Request', () async {
        BaseRequest? seen;
        final broker = family.build(
          MockClient.streaming((request, body) async {
            await body.drain<void>();
            seen = request;
            return StreamedResponse(const Stream.empty(), 400);
          }),
        );
        await expectLater(
          broker.chatWithMeta(
            apiKey: 'k',
            model: 'm',
            request: _request,
          ),
          throwsA(anything),
        );
        expect(seen, isNot(isA<Abortable>()));
      });

      test(
          'streamWithMeta: aborting mid-stream ends the deltas and fails '
          'the completion', () async {
        final fake = _StreamingClient();
        final broker = family.build(fake.client);
        final trigger = Completer<void>();
        final turn = broker.streamWithMeta(
          apiKey: 'k',
          model: 'm',
          request: _request,
          abortTrigger: trigger.future,
        );
        final deltas = <String>[];
        final errors = <Object>[];
        final done = Completer<void>();
        turn.deltas.listen(
          (delta) {
            deltas.add(delta);
            if (!trigger.isCompleted) trigger.complete();
          },
          onError: errors.add,
          onDone: done.complete,
        );
        fake.body.add(utf8.encode(family.sseEvent));
        await done.future;
        expect(deltas, ['Hel']);
        expect(errors, [isA<AiAbortedException>()]);
        await expectLater(turn.completion, throwsA(isA<AiAbortedException>()));
        expect(fake.bodyCancelled, isTrue);
      });

      test('stream: a trigger that already completed sends nothing', () async {
        final fake = _StreamingClient();
        final broker = family.build(fake.client);
        await expectLater(
          broker
              .stream(
                apiKey: 'k',
                model: 'm',
                request: _request,
                abortTrigger: Future<void>.value(),
              )
              .toList(),
          throwsA(isA<AiAbortedException>()),
        );
        expect(fake.calls, 0);
      });
    });
  }

  test('an aborted completion nobody listens to is not reported as unhandled',
      () async {
    final fake = _StreamingClient();
    final broker = AnthropicBroker(client: fake.client);
    final trigger = Completer<void>();
    // `stream()` drops the completion on the floor; the zone would fail this
    // test if its error escaped.
    final errors = <Object>[];
    final done = Completer<void>();
    broker
        .stream(
          apiKey: 'k',
          model: 'm',
          request: _request,
          abortTrigger: trigger.future,
        )
        .listen(
          (_) => trigger.complete(),
          onError: errors.add,
          onDone: done.complete,
        );
    fake.body.add(utf8.encode(_families.first.sseEvent));
    await done.future;
    expect(errors, [isA<AiAbortedException>()]);
  });

  group('abortTrigger with the default client', () {
    late ServerSocket server;
    late Completer<void> received;
    late Completer<void> closed;

    setUp(() async {
      received = Completer<void>();
      closed = Completer<void>();
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() => server.close());

    /// Accepts one connection and reports when the request arrives and when
    /// the client closes the socket. [reply] is written once the request
    /// arrives; without it the server never answers.
    void serve({String? reply}) {
      server.listen((socket) {
        socket.listen(
          (_) {
            if (received.isCompleted) return;
            received.complete();
            if (reply != null) socket.add(utf8.encode(reply));
          },
          onError: (Object _) {},
          onDone: () {
            if (!closed.isCompleted) closed.complete();
            socket.destroy();
          },
        );
      });
    }

    String baseUrl() => 'http://127.0.0.1:${server.port}/v1';

    test('chat: the connection is closed', () async {
      serve();
      final broker = AnthropicBroker(baseUrl: baseUrl());
      final trigger = Completer<void>();
      final call = broker.chat(
        apiKey: 'k',
        model: 'm',
        request: _request,
        abortTrigger: trigger.future,
      );
      await received.future;
      trigger.complete();
      await expectLater(call, throwsA(isA<AiAbortedException>()));
      await closed.future.timeout(const Duration(seconds: 5));
    });

    test('stream: the connection is closed mid-reply', () async {
      serve(
        reply: 'HTTP/1.1 200 OK\r\n'
            'Content-Type: text/event-stream\r\n'
            'Connection: close\r\n'
            '\r\n'
            'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n',
      );
      final broker = OpenAiCompatibleBroker(
        id: 'local',
        label: 'Local',
        baseUrl: baseUrl(),
      );
      final trigger = Completer<void>();
      final deltas = <String>[];
      final errors = <Object>[];
      final done = Completer<void>();
      broker
          .stream(
        apiKey: 'k',
        model: 'm',
        request: _request,
        abortTrigger: trigger.future,
      )
          .listen(
        (delta) {
          deltas.add(delta);
          if (!trigger.isCompleted) trigger.complete();
        },
        onError: errors.add,
        onDone: done.complete,
      );
      await done.future.timeout(const Duration(seconds: 5));
      expect(deltas, ['Hel']);
      expect(errors, [isA<AiAbortedException>()]);
      await closed.future.timeout(const Duration(seconds: 5));
    });
  });
}
