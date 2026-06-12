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
  group('GeminiBroker', () {
    test('id and label', () {
      final b = GeminiBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      expect(b.id, 'gemini');
      expect(b.label, 'Google (Gemini)');
    });

    group('listModels', () {
      test('returns empty list immediately for an empty key', () async {
        var called = false;
        final b = GeminiBroker(
          client: MockClient((_) async {
            called = true;
            return Response('', 200);
          }),
        );
        expect(await b.listModels(''), isEmpty);
        expect(called, isFalse);
      });

      test('keeps only gemini-* models that support generateContent', () async {
        final b = GeminiBroker(
          client: MockClient((req) async {
            expect(req.headers['x-goog-api-key'], 'g-key');
            expect(req.url.queryParameters.containsKey('key'), isFalse);
            return Response(
              jsonEncode({
                'models': [
                  {
                    'name': 'models/gemini-2.5-pro',
                    'supportedGenerationMethods': ['generateContent'],
                  },
                  {
                    'name': 'models/gemini-1.5-flash',
                    'supportedGenerationMethods': [
                      'generateContent',
                      'streamGenerateContent',
                    ],
                  },
                  {
                    'name': 'models/embedding-001',
                    'supportedGenerationMethods': ['embedContent'],
                  },
                  {
                    'name': 'models/gemini-embedding-001',
                    // Lacks generateContent → filtered out.
                    'supportedGenerationMethods': ['embedContent'],
                  },
                ],
              }),
              200,
            );
          }),
        );
        final ids = await b.listModels('g-key');
        expect(ids, ['gemini-2.5-pro', 'gemini-1.5-flash']);
      });

      test('paginates with nextPageToken across multiple pages', () async {
        final pages = [
          {
            'models': [
              {
                'name': 'models/gemini-2.0-flash',
                'supportedGenerationMethods': ['generateContent'],
              },
            ],
            'nextPageToken': 'p2',
          },
          {
            'models': [
              {
                'name': 'models/gemini-1.5-flash',
                'supportedGenerationMethods': ['generateContent'],
              },
            ],
          },
        ];
        var pageIndex = 0;
        final b = GeminiBroker(
          client: MockClient((req) async {
            if (pageIndex == 0) {
              expect(req.url.queryParameters.containsKey('pageToken'), isFalse);
            } else {
              expect(req.url.queryParameters['pageToken'], 'p2');
            }
            final body = pages[pageIndex++];
            return Response(jsonEncode(body), 200);
          }),
        );
        final ids = await b.listModels('g-key');
        expect(ids, ['gemini-2.0-flash', 'gemini-1.5-flash']);
        expect(pageIndex, 2);
      });

      test('returns empty list on 4xx', () async {
        final b = GeminiBroker(
          client: MockClient((_) async => Response('nope', 400)),
        );
        expect(await b.listModels('bad'), isEmpty);
      });
    });

    group('chat', () {
      test(
          'puts key in query, system in systemInstruction, and reads '
          'candidates[].content.parts[].text', () async {
        late Map<String, Object?> sentBody;
        late Uri sentUri;
        late Map<String, String> sentHeaders;
        final b = GeminiBroker(
          client: MockClient((req) async {
            sentUri = req.url;
            sentHeaders = req.headers;
            sentBody = jsonDecode(req.body) as Map<String, Object?>;
            return Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'hello '},
                        {'text': 'world'},
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );
        final out = await b.chat(
          apiKey: 'g-key',
          model: 'gemini-2.5-pro',
          request: const ChatRequest(
            system: 'be precise',
            messages: [
              AiMessage.user('hi'),
              AiMessage.assistant('hello'),
            ],
            temperature: 0.7,
            maxTokens: 32,
          ),
        );
        expect(out, 'hello world');
        expect(
          sentUri.path,
          '/v1beta/models/gemini-2.5-pro:generateContent',
        );
        expect(sentHeaders['x-goog-api-key'], 'g-key');
        expect(sentUri.queryParameters.containsKey('key'), isFalse);
        expect(
          sentBody['systemInstruction'],
          {
            'parts': [
              {'text': 'be precise'},
            ],
          },
        );
        final contents = sentBody['contents'] as List<Object?>;
        expect(contents, [
          {
            'role': 'user',
            'parts': [
              {'text': 'hi'},
            ],
          },
          {
            'role': 'model',
            'parts': [
              {'text': 'hello'},
            ],
          },
        ]);
        expect(
          sentBody['generationConfig'],
          {'temperature': 0.7, 'maxOutputTokens': 32},
        );
      });

      test('omits systemInstruction when the system prompt is empty', () async {
        late Map<String, Object?> sentBody;
        final b = GeminiBroker(
          client: MockClient((req) async {
            sentBody = jsonDecode(req.body) as Map<String, Object?>;
            return Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'x'},
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }),
        );
        await b.chat(
          apiKey: 'g',
          model: 'gemini-2.5-pro',
          request: const ChatRequest(
            system: '',
            messages: [AiMessage.user('hi')],
          ),
        );
        expect(sentBody.containsKey('systemInstruction'), isFalse);
      });

      test('throws when no candidates are returned', () async {
        final b = GeminiBroker(
          client: MockClient(
            (_) async => Response(jsonEncode({'candidates': <dynamic>[]}), 200),
          ),
        );
        await expectLater(
          b.chat(
            apiKey: 'g',
            model: 'm',
            request: const ChatRequest(system: '', messages: []),
          ),
          throwsA(
            isA<AiBrokerException>()
                .having((e) => e.message, 'message', contains('no candidates')),
          ),
        );
      });

      test('throws when the candidate text is empty', () async {
        final b = GeminiBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': ''},
                      ],
                    },
                  },
                ],
              }),
              200,
            ),
          ),
        );
        await expectLater(
          b.chat(
            apiKey: 'g',
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
      test('forces ?alt=sse and yields text from each candidate chunk',
          () async {
        late Uri sentUri;
        final body = StringBuffer()
          ..writeln('data: ${jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'first '},
                      ],
                    },
                  },
                ],
              })}')
          ..writeln()
          ..writeln('data: ${jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'second'},
                      ],
                    },
                  },
                ],
              })}')
          ..writeln();
        late Map<String, String> sentHeaders;
        final b = GeminiBroker(
          client: MockClient.streaming((req, _) async {
            sentUri = req.url;
            sentHeaders = req.headers;
            return StreamedResponse(
              Stream<List<int>>.value(utf8.encode(body.toString())),
              200,
            );
          }),
        );
        final chunks = await b
            .stream(
              apiKey: 'g',
              model: 'gemini-2.5-pro',
              request: const ChatRequest(
                system: '',
                messages: [AiMessage.user('hi')],
              ),
            )
            .toList();
        expect(chunks, ['first ', 'second']);
        expect(
          sentUri.path,
          '/v1beta/models/gemini-2.5-pro:streamGenerateContent',
        );
        expect(sentUri.queryParameters['alt'], 'sse');
        expect(sentUri.queryParameters.containsKey('key'), isFalse);
        expect(sentHeaders['x-goog-api-key'], 'g');
      });

      test('skips chunks with no candidates rather than throwing', () async {
        final body = StringBuffer()
          ..writeln('data: ${jsonEncode({'candidates': <dynamic>[]})}')
          ..writeln()
          ..writeln('data: ${jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'ok'},
                      ],
                    },
                  },
                ],
              })}')
          ..writeln();
        final b = GeminiBroker(
          client: MockClient.streaming(
            (_, __) async => StreamedResponse(
              Stream<List<int>>.value(utf8.encode(body.toString())),
              200,
            ),
          ),
        );
        final chunks = await b
            .stream(
              apiKey: 'g',
              model: 'gemini-2.5-pro',
              request: const ChatRequest(system: '', messages: []),
            )
            .toList();
        expect(chunks, ['ok']);
      });
    });

    group('embed', () {
      test('posts batchEmbedContents and returns vectors in order', () async {
        late Map<String, Object?> sentBody;
        final b = GeminiBroker(
          client: MockClient((req) async {
            expect(req.method, 'POST');
            expect(
              req.url.toString(),
              'https://generativelanguage.googleapis.com/v1beta/'
              'models/text-embedding-004:batchEmbedContents',
            );
            expect(req.headers['x-goog-api-key'], 'g-test');
            expect(req.headers['Content-Type'], 'application/json');
            sentBody = jsonDecode(req.body) as Map<String, Object?>;
            return Response(
              jsonEncode({
                'embeddings': [
                  {
                    'values': [0.1, 0.2, 0.3],
                  },
                  {
                    'values': [0.4, 0.5, 0.6],
                  },
                ],
              }),
              200,
            );
          }),
        );
        final out = await b.embed(
          apiKey: 'g-test',
          model: 'text-embedding-004',
          inputs: ['hello', 'world'],
        );
        // Body wraps each input as a per-item request with the prefixed model.
        final requests = sentBody['requests'] as List<Object?>;
        expect(requests, hasLength(2));
        final first = requests[0] as Map<String, Object?>;
        expect(first['model'], 'models/text-embedding-004');
        final parts =
            ((first['content'] as Map<String, Object?>)['parts'] as List);
        expect((parts.first as Map<String, Object?>)['text'], 'hello');
        expect(out, [
          [0.1, 0.2, 0.3],
          [0.4, 0.5, 0.6],
        ]);
      });

      test('accepts a model id already prefixed with models/', () async {
        Uri? sentUri;
        final b = GeminiBroker(
          client: MockClient((req) async {
            sentUri = req.url;
            return Response(
              jsonEncode({
                'embeddings': [
                  {
                    'values': [0.0],
                  },
                ],
              }),
              200,
            );
          }),
        );
        await b.embed(
          apiKey: 'g',
          model: 'models/text-embedding-004',
          inputs: const ['hi'],
        );
        expect(
          sentUri.toString(),
          'https://generativelanguage.googleapis.com/v1beta/'
          'models/text-embedding-004:batchEmbedContents',
        );
      });

      test('returns empty list without hitting the network for empty inputs',
          () async {
        var called = false;
        final b = GeminiBroker(
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

      test('throws AiBrokerException on 4xx', () async {
        final b = GeminiBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'error': {'message': 'bad key'},
              }),
              403,
            ),
          ),
        );
        await expectLater(
          b.embed(apiKey: 'k', model: 'm', inputs: const ['a']),
          throwsA(
            isA<AiBrokerException>()
                .having((e) => e.statusCode, 'statusCode', 403),
          ),
        );
      });
    });
  });
}
