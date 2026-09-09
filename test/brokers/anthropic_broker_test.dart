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
import 'dart:convert';

import 'package:ai_broker/ai_broker.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('AnthropicBroker', () {
    test('id and label', () {
      final b = AnthropicBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      expect(b.id, 'anthropic');
      expect(b.label, 'Anthropic (Claude)');
    });

    group('listModels', () {
      test('returns empty list immediately for an empty key', () async {
        var called = false;
        final b = AnthropicBroker(
          client: MockClient((_) async {
            called = true;
            return Response('', 200);
          }),
        );
        expect(await b.listModels(''), isEmpty);
        expect(called, isFalse);
      });

      test('sends x-api-key and anthropic-version headers', () async {
        final b = AnthropicBroker(
          client: MockClient((req) async {
            expect(req.url.toString(), 'https://api.anthropic.com/v1/models');
            expect(req.headers['x-api-key'], 'k');
            expect(req.headers['anthropic-version'], '2023-06-01');
            return Response(jsonEncode({'data': <dynamic>[]}), 200);
          }),
        );
        await b.listModels('k');
      });

      test('returns ids sorted descending so newer models come first',
          () async {
        final b = AnthropicBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'data': [
                  {'id': 'claude-3-5-sonnet'},
                  {'id': 'claude-opus-4-7'},
                  {'id': 'claude-haiku-4-5'},
                ],
              }),
              200,
            ),
          ),
        );
        final ids = await b.listModels('k');
        expect(ids, [
          'claude-opus-4-7',
          'claude-haiku-4-5',
          'claude-3-5-sonnet',
        ]);
      });

      test('sorts ids with digit-aware ordering so 3-10 ranks above 3-7',
          () async {
        // Plain lex would put `3-7` first (`'7' > '1'`). The broker must
        // parse numeric runs so a future two-digit minor sorts correctly.
        final b = AnthropicBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'data': [
                  {'id': 'claude-3-7-sonnet'},
                  {'id': 'claude-3-10-sonnet'},
                  {'id': 'claude-3-2-sonnet'},
                ],
              }),
              200,
            ),
          ),
        );
        expect(await b.listModels('k'), [
          'claude-3-10-sonnet',
          'claude-3-7-sonnet',
          'claude-3-2-sonnet',
        ]);
      });

      test('returns empty list on 4xx', () async {
        final b = AnthropicBroker(
          client: MockClient((_) async => Response('nope', 401)),
        );
        expect(await b.listModels('bad'), isEmpty);
      });
    });

    group('chat', () {
      test('puts system at the top level and concatenates text blocks',
          () async {
        late Map<String, Object?> sentBody;
        final b = AnthropicBroker(
          client: MockClient((req) async {
            expect(req.url.toString(), 'https://api.anthropic.com/v1/messages');
            expect(req.headers['x-api-key'], 'k');
            sentBody = jsonDecode(req.body) as Map<String, Object?>;
            return Response(
              jsonEncode({
                'content': [
                  {'type': 'text', 'text': 'hello, '},
                  {'type': 'tool_use', 'name': 'ignored'},
                  {'type': 'text', 'text': 'world'},
                ],
              }),
              200,
            );
          }),
        );
        final out = await b.chat(
          apiKey: 'k',
          model: 'claude-opus-4-7',
          request: const ChatRequest(
            system: 'you are a poet',
            messages: [AiMessage.user('hi')],
            temperature: 0.4,
            maxTokens: 100,
          ),
        );
        expect(out, 'hello, world');
        expect(sentBody['system'], 'you are a poet');
        expect(sentBody['model'], 'claude-opus-4-7');
        expect(sentBody['max_tokens'], 100);
        expect(sentBody['temperature'], 0.4);
        expect(sentBody.containsKey('stream'), isFalse);
        final messages = sentBody['messages'] as List<Object?>;
        expect(messages, [
          {'role': 'user', 'content': 'hi'},
        ]);
      });

      // An empty content list and an all-whitespace reply are the same
      // failure to a caller of `chat`; `chatDetailed` is the API that
      // distinguishes them (a refusal returns empty text, not an exception).
      test('throws when content list is empty', () async {
        final b = AnthropicBroker(
          client: MockClient(
            (_) async => Response(jsonEncode({'content': <dynamic>[]}), 200),
          ),
        );
        await expectLater(
          b.chat(
            apiKey: 'k',
            model: 'm',
            request: const ChatRequest(system: '', messages: []),
          ),
          throwsA(
            isA<AiBrokerException>()
                .having((e) => e.message, 'message', contains('empty text')),
          ),
        );
      });

      test('throws when only non-text blocks are returned', () async {
        final b = AnthropicBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'content': [
                  {'type': 'tool_use', 'name': 'x'},
                ],
              }),
              200,
            ),
          ),
        );
        await expectLater(
          b.chat(
            apiKey: 'k',
            model: 'm',
            request: const ChatRequest(system: '', messages: []),
          ),
          throwsA(
            isA<AiBrokerException>()
                .having((e) => e.message, 'message', contains('empty text')),
          ),
        );
      });
    });

    group('stream', () {
      test('emits text_delta payloads and stops on message_stop', () async {
        final body = StringBuffer()
          ..writeln('event: message_start')
          ..writeln('data: {}')
          ..writeln()
          ..writeln('event: content_block_delta')
          ..writeln('data: ${jsonEncode({
                'delta': {'type': 'text_delta', 'text': 'foo '},
              })}')
          ..writeln()
          ..writeln('event: content_block_delta')
          ..writeln('data: ${jsonEncode({
                'delta': {'type': 'text_delta', 'text': 'bar'},
              })}')
          ..writeln()
          ..writeln('event: message_stop')
          ..writeln('data: {}')
          ..writeln()
          ..writeln('event: content_block_delta')
          ..writeln('data: ${jsonEncode({
                'delta': {'type': 'text_delta', 'text': 'never'},
              })}')
          ..writeln();
        final b = AnthropicBroker(
          client: MockClient.streaming(
            (_, __) async => StreamedResponse(
              Stream<List<int>>.value(utf8.encode(body.toString())),
              200,
            ),
          ),
        );
        final chunks = await b
            .stream(
              apiKey: 'k',
              model: 'claude-opus-4-7',
              request: const ChatRequest(system: '', messages: []),
            )
            .toList();
        expect(chunks, ['foo ', 'bar']);
      });

      test('ignores non-text deltas and ping events', () async {
        final body = StringBuffer()
          ..writeln('event: ping')
          ..writeln('data: {}')
          ..writeln()
          ..writeln('event: content_block_delta')
          ..writeln('data: ${jsonEncode({
                'delta': {'type': 'input_json_delta', 'partial_json': '{}'},
              })}')
          ..writeln()
          ..writeln('event: content_block_delta')
          ..writeln('data: ${jsonEncode({
                'delta': {'type': 'text_delta', 'text': 'ok'},
              })}')
          ..writeln()
          ..writeln('event: message_stop')
          ..writeln('data: {}')
          ..writeln();
        final b = AnthropicBroker(
          client: MockClient.streaming(
            (_, __) async => StreamedResponse(
              Stream<List<int>>.value(utf8.encode(body.toString())),
              200,
            ),
          ),
        );
        final chunks = await b
            .stream(
              apiKey: 'k',
              model: 'claude-opus-4-7',
              request: const ChatRequest(system: '', messages: []),
            )
            .toList();
        expect(chunks, ['ok']);
      });
    });

    group('streamDetailed', () {
      const request = ChatRequest(system: '', messages: []);

      test('yields each delta as it lands, then reports the accounting',
          () async {
        // A controller for the wire, so the test decides exactly when each
        // SSE event shows up and can check what the consumer has seen in
        // between. If anything buffered the reply, `seen` would stay empty
        // until the last chunk.
        final wire = StreamController<List<int>>();
        final b = AnthropicBroker(
          client: MockClient.streaming(
            (_, __) async => StreamedResponse(wire.stream, 200),
          ),
        );
        final turn = b.streamDetailed(
          apiKey: 'k',
          model: 'claude-opus-5',
          request: request,
        );
        var settled = false;
        unawaited(turn.completion.then((_) => settled = true));
        final seen = <String>[];
        final sub = turn.deltas.listen(seen.add);

        wire.add(
          utf8.encode(
            _sse('message_start', {
              'message': {
                'model': 'claude-opus-5-20260501',
                'usage': {
                  'input_tokens': 812,
                  'cache_read_input_tokens': 700,
                  'cache_creation_input_tokens': 12,
                  'output_tokens': 1,
                },
              },
            }),
          ),
        );
        await _pump();
        expect(seen, isEmpty, reason: 'message_start carries no text');

        wire.add(utf8.encode(_textDelta('foo ')));
        await _pump();
        expect(seen, ['foo '], reason: 'delta must arrive before the end');
        expect(settled, isFalse);

        wire.add(utf8.encode(_textDelta('bar')));
        await _pump();
        expect(seen, ['foo ', 'bar']);
        expect(settled, isFalse, reason: 'nothing has ended the turn yet');

        wire
          ..add(
            utf8.encode(
              _sse('message_delta', {
                'delta': {'stop_reason': 'max_tokens'},
                'usage': {'output_tokens': 42},
              }),
            ),
          )
          ..add(utf8.encode(_sse('message_stop', const {})));

        final done = await turn.completion;
        expect(done.text, 'foo bar');
        expect(
          done.model,
          'claude-opus-5-20260501',
          reason: 'message_start names the model that actually served it',
        );
        expect(done.stopReason, AiStopReason.maxTokens);
        expect(done.isTruncated, isTrue);
        expect(done.inputTokens, 812);
        expect(
          done.outputTokens,
          42,
          reason: "message_delta's final count wins over message_start's",
        );
        expect(done.cacheReadInputTokens, 700);
        expect(done.cacheCreationInputTokens, 12);

        await sub.cancel();
        await wire.close();
      });

      test('a mid-stream refusal is a completion, not an error', () async {
        final body = StringBuffer()
          ..write(
            _sse('message_start', {
              'message': {
                'model': 'claude-opus-5',
                'usage': {'input_tokens': 20},
              },
            }),
          )
          ..write(_textDelta("I can't help with that."))
          ..write(
            _sse('message_delta', {
              'delta': {'stop_reason': 'refusal'},
              'usage': {'output_tokens': 7},
            }),
          )
          ..write(_sse('message_stop', const {}));
        final b = AnthropicBroker(
          client: MockClient.streaming(
            (_, __) async => StreamedResponse(
              Stream<List<int>>.value(utf8.encode(body.toString())),
              200,
            ),
          ),
        );
        final turn = b.streamDetailed(
          apiKey: 'k',
          model: 'claude-opus-5',
          request: request,
        );
        expect(await turn.deltas.toList(), ["I can't help with that."]);
        final done = await turn.completion;
        expect(done.stopReason, AiStopReason.refusal);
        expect(done.isRefusal, isTrue);
        expect(done.text, "I can't help with that.");
        expect(done.inputTokens, 20);
        expect(done.outputTokens, 7);
      });

      test('reports `unknown` when the stream ends without a message_delta',
          () async {
        final body = StringBuffer()
          ..write(_textDelta('cut short'))
          ..write(_sse('message_stop', const {}));
        final b = AnthropicBroker(
          client: MockClient.streaming(
            (_, __) async => StreamedResponse(
              Stream<List<int>>.value(utf8.encode(body.toString())),
              200,
            ),
          ),
        );
        final turn = b.streamDetailed(
          apiKey: 'k',
          model: 'claude-opus-5',
          request: request,
        );
        await turn.deltas.toList();
        final done = await turn.completion;
        expect(done.stopReason, AiStopReason.unknown);
        expect(done.model, 'claude-opus-5', reason: 'falls back to requested');
      });

      test('a failed request fails the deltas and the completion alike',
          () async {
        final b = AnthropicBroker(
          client: MockClient.streaming(
            (_, __) async => StreamedResponse(
              Stream<List<int>>.value(utf8.encode('overloaded')),
              529,
            ),
          ),
        );
        final turn = b.streamDetailed(
          apiKey: 'k',
          model: 'claude-opus-5',
          request: request,
        );
        await expectLater(
          turn.deltas.toList(),
          throwsA(isA<AiBrokerException>()),
        );
        await expectLater(turn.completion, throwsA(isA<AiBrokerException>()));
      });

      test('stream() failing raises no unhandled async error', () async {
        // `stream()` is `streamDetailed().deltas` — nobody awaits the
        // completion future, so its error must not escape the zone.
        final errors = <Object>[];
        await runZonedGuarded(
          () async {
            final b = AnthropicBroker(
              client: MockClient.streaming(
                (_, __) async => StreamedResponse(
                  Stream<List<int>>.value(utf8.encode('nope')),
                  500,
                ),
              ),
            );
            await b
                .stream(apiKey: 'k', model: 'claude-opus-5', request: request)
                .toList()
                .catchError((Object _) => <String>[]);
            await _pump();
          },
          (e, _) => errors.add(e),
        );
        expect(errors, isEmpty);
      });
    });

    test(
        'does NOT implement EmbedBroker (Anthropic has no first-party '
        'embeddings)', () {
      final b =
          AnthropicBroker(client: MockClient((_) async => Response('', 200)));
      expect(b, isA<ChatBroker>());
      expect(b, isNot(isA<EmbedBroker>()));
    });
  });
}

/// One framed SSE event, exactly as Anthropic writes it.
String _sse(String event, Map<String, Object?> data) =>
    'event: $event\ndata: ${jsonEncode(data)}\n\n';

String _textDelta(String text) => _sse('content_block_delta', {
      'delta': {'type': 'text_delta', 'text': text},
    });

/// Hands whatever has arrived to the listener before the test looks at it.
/// A few event-loop turns, not one: the SSE decoder and the generator behind
/// the deltas each cost a turn.
Future<void> _pump() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
