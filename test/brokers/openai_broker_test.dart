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
  group('OpenAiBroker', () {
    test('id and label', () {
      final b =
          OpenAiBroker(client: MockClient((_) async => Response('', 200)));
      expect(b.id, 'openai');
      expect(b.label, 'OpenAI');
    });

    group('listModels', () {
      test('returns empty list immediately for an empty key', () async {
        var called = false;
        final b = OpenAiBroker(
          client: MockClient((_) async {
            called = true;
            return Response('', 200);
          }),
        );
        expect(await b.listModels(''), isEmpty);
        expect(called, isFalse);
      });

      test('filters to chat-capable models and sorts ascending', () async {
        final b = OpenAiBroker(
          client: MockClient((req) async {
            expect(req.method, 'GET');
            expect(req.url.toString(), 'https://api.openai.com/v1/models');
            expect(req.headers['Authorization'], 'Bearer sk-test');
            return Response(
              jsonEncode({
                'data': [
                  {'id': 'gpt-4o-mini'},
                  {'id': 'gpt-4'},
                  {'id': 'text-embedding-3-small'}, // filtered out
                  {'id': 'o1-preview'},
                  {'id': 'whisper-1'}, // filtered out
                  {'id': 'dall-e-3'}, // filtered out
                ],
              }),
              200,
            );
          }),
        );
        final models = await b.listModels('sk-test');
        expect(models, ['gpt-4', 'gpt-4o-mini', 'o1-preview']);
      });

      test('returns empty list on 4xx', () async {
        final b = OpenAiBroker(
          client: MockClient((_) async => Response('unauthorized', 401)),
        );
        expect(await b.listModels('sk-bad'), isEmpty);
      });

      test('skips malformed entries gracefully', () async {
        final b = OpenAiBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'data': [
                  'not-a-map',
                  {'no-id': true},
                  {'id': 'gpt-4o'},
                ],
              }),
              200,
            ),
          ),
        );
        expect(await b.listModels('sk'), ['gpt-4o']);
      });
    });

    group('chat', () {
      test('builds the documented payload and returns trimmed content',
          () async {
        late Map<String, Object?> sentBody;
        final b = OpenAiBroker(
          client: MockClient((req) async {
            expect(req.method, 'POST');
            expect(
              req.url.toString(),
              'https://api.openai.com/v1/chat/completions',
            );
            expect(req.headers['Authorization'], 'Bearer sk-test');
            expect(req.headers['Content-Type'], 'application/json');
            sentBody = jsonDecode(req.body) as Map<String, Object?>;
            return Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '  hello, world  '},
                  },
                ],
              }),
              200,
            );
          }),
        );
        final out = await b.chat(
          apiKey: 'sk-test',
          model: 'gpt-4o',
          request: const ChatRequest(
            system: 'be brief',
            messages: [
              AiMessage.user('hi'),
              AiMessage.assistant('hello'),
              AiMessage.user('again'),
            ],
            temperature: 0.5,
            maxTokens: 64,
          ),
        );
        expect(out, 'hello, world');
        expect(sentBody['model'], 'gpt-4o');
        expect(sentBody['temperature'], 0.5);
        expect(sentBody['max_tokens'], 64);
        expect(sentBody.containsKey('stream'), isFalse);
        final messages = sentBody['messages'] as List<Object?>;
        expect(messages, hasLength(4));
        expect(
          messages.first,
          {'role': 'system', 'content': 'be brief'},
        );
        expect(
          messages[1],
          {'role': 'user', 'content': 'hi'},
        );
        expect(
          messages[2],
          {'role': 'assistant', 'content': 'hello'},
        );
        expect(
          messages.last,
          {'role': 'user', 'content': 'again'},
        );
      });

      test('throws AiBrokerException when no choices are returned', () async {
        final b = OpenAiBroker(
          client: MockClient(
            (_) async => Response(jsonEncode({'choices': <dynamic>[]}), 200),
          ),
        );
        await expectLater(
          b.chat(
            apiKey: 'k',
            model: 'gpt-4o',
            request: const ChatRequest(system: '', messages: []),
          ),
          throwsA(
            isA<AiBrokerException>()
                .having((e) => e.message, 'message', contains('no choices')),
          ),
        );
      });

      test('throws AiBrokerException when content is empty', () async {
        final b = OpenAiBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': ''},
                  },
                ],
              }),
              200,
            ),
          ),
        );
        await expectLater(
          b.chat(
            apiKey: 'k',
            model: 'gpt-4o',
            request: const ChatRequest(system: '', messages: []),
          ),
          throwsA(
            isA<AiBrokerException>()
                .having((e) => e.message, 'message', contains('empty content')),
          ),
        );
      });
    });

    group('complete', () {
      test('delegates to chat with a single user message', () async {
        late Map<String, Object?> sentBody;
        final b = OpenAiBroker(
          client: MockClient((req) async {
            sentBody = jsonDecode(req.body) as Map<String, Object?>;
            return Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'ok'},
                  },
                ],
              }),
              200,
            );
          }),
        );
        final out = await b.complete(
          apiKey: 'k',
          model: 'gpt-4o',
          system: 'sys',
          user: 'hello',
        );
        expect(out, 'ok');
        final messages = sentBody['messages'] as List<Object?>;
        expect(messages, hasLength(2));
        expect(messages.last, {'role': 'user', 'content': 'hello'});
      });
    });

    group('stream', () {
      test('decodes SSE deltas and stops on [DONE]', () async {
        final body = StringBuffer()
          ..writeln('data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': 'hel'},
                  },
                ],
              })}')
          ..writeln()
          ..writeln('data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': 'lo'},
                  },
                ],
              })}')
          ..writeln()
          ..writeln('data: [DONE]')
          ..writeln()
          ..writeln('data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': 'never'},
                  },
                ],
              })}')
          ..writeln();
        final b = OpenAiBroker(
          client: MockClient.streaming((req, _) async {
            expect(req.headers['Accept'], 'text/event-stream');
            return StreamedResponse(
              Stream<List<int>>.value(utf8.encode(body.toString())),
              200,
            );
          }),
        );
        final chunks = await b
            .stream(
              apiKey: 'k',
              model: 'gpt-4o',
              request: const ChatRequest(system: '', messages: []),
            )
            .toList();
        expect(chunks, ['hel', 'lo']);
      });

      test('skips empty delta chunks', () async {
        final body = StringBuffer()
          ..writeln('data: ${jsonEncode({
                'choices': [
                  {'delta': <String, Object?>{}},
                ],
              })}')
          ..writeln()
          ..writeln('data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': 'x'},
                  },
                ],
              })}')
          ..writeln()
          ..writeln('data: [DONE]')
          ..writeln();
        final b = OpenAiBroker(
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
              model: 'gpt-4o',
              request: const ChatRequest(system: '', messages: []),
            )
            .toList();
        expect(chunks, ['x']);
      });

      test('surfaces non-2xx as AiBrokerException', () async {
        final b = OpenAiBroker(
          client: MockClient.streaming(
            (_, __) async => StreamedResponse(
              Stream<List<int>>.value(utf8.encode('nope')),
              401,
            ),
          ),
        );
        await expectLater(
          b
              .stream(
                apiKey: 'k',
                model: 'gpt-4o',
                request: const ChatRequest(system: '', messages: []),
              )
              .toList(),
          throwsA(
            isA<AiBrokerException>()
                .having((e) => e.statusCode, 'statusCode', 401),
          ),
        );
      });
    });

    group('embed', () {
      test('posts the documented payload and returns vectors in order',
          () async {
        late Map<String, Object?> sentBody;
        final b = OpenAiBroker(
          client: MockClient((req) async {
            expect(req.method, 'POST');
            expect(
              req.url.toString(),
              'https://api.openai.com/v1/embeddings',
            );
            expect(req.headers['Authorization'], 'Bearer sk-test');
            expect(req.headers['Content-Type'], 'application/json');
            sentBody = jsonDecode(req.body) as Map<String, Object?>;
            return Response(
              jsonEncode({
                'data': [
                  {
                    'index': 1,
                    'embedding': [0.4, 0.5, 0.6],
                  },
                  {
                    'index': 0,
                    'embedding': [0.1, 0.2, 0.3],
                  },
                ],
              }),
              200,
            );
          }),
        );
        final out = await b.embed(
          apiKey: 'sk-test',
          model: 'text-embedding-3-small',
          inputs: ['hello', 'world'],
        );
        expect(sentBody['model'], 'text-embedding-3-small');
        expect(sentBody['input'], ['hello', 'world']);
        expect(sentBody['encoding_format'], 'float');
        // Returned in input order, not server order — defensive sort by index.
        expect(out, [
          [0.1, 0.2, 0.3],
          [0.4, 0.5, 0.6],
        ]);
      });

      test('returns empty list without hitting the network for empty inputs',
          () async {
        var called = false;
        final b = OpenAiBroker(
          client: MockClient((_) async {
            called = true;
            return Response('', 200);
          }),
        );
        expect(
          await b.embed(apiKey: 'k', model: 'm', inputs: const []),
          isEmpty,
        );
        expect(called, isFalse);
      });

      test('throws when response count does not match input count', () async {
        final b = OpenAiBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'data': [
                  {
                    'index': 0,
                    'embedding': [0.1],
                  },
                ],
              }),
              200,
            ),
          ),
        );
        await expectLater(
          b.embed(apiKey: 'k', model: 'm', inputs: const ['a', 'b']),
          throwsA(isA<AiBrokerException>()),
        );
      });

      test('throws AiBrokerException on 4xx', () async {
        final b = OpenAiBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'error': {'message': 'bad key'},
              }),
              401,
            ),
          ),
        );
        await expectLater(
          b.embed(apiKey: 'k', model: 'm', inputs: const ['a']),
          throwsA(
            isA<AiBrokerException>()
                .having((e) => e.statusCode, 'statusCode', 401),
          ),
        );
      });
    });
  });
}
