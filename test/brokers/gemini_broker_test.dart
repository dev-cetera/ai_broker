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

import '../support/judge_schema.dart';

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

    group('streamDetailed', () {
      const request = ChatRequest(system: '', messages: []);

      GeminiBroker brokerFor(String body) => GeminiBroker(
            client: MockClient.streaming(
              (_, __) async => StreamedResponse(
                Stream<List<int>>.value(utf8.encode(body)),
                200,
              ),
            ),
          );

      test('picks up usageMetadata and the serving model from the last chunk',
          () async {
        // Gemini settles usageMetadata on the final chunk; the earlier ones
        // carry text only.
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
                'modelVersion': 'gemini-2.5-pro-002',
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
                    'finishReason': 'STOP',
                  },
                ],
                'usageMetadata': {
                  'promptTokenCount': 31,
                  'candidatesTokenCount': 9,
                  'cachedContentTokenCount': 4,
                  'totalTokenCount': 40,
                },
              })}')
          ..writeln();
        final b = brokerFor(body.toString());
        final turn = b.streamDetailed(
          apiKey: 'g',
          model: 'gemini-2.5-pro',
          request: request,
        );
        expect(await turn.deltas.toList(), ['first ', 'second']);
        final done = await turn.completion;
        expect(done.text, 'first second');
        expect(done.model, 'gemini-2.5-pro-002');
        expect(done.stopReason, AiStopReason.endTurn);
        expect(done.inputTokens, 31);
        expect(done.outputTokens, 9);
        expect(done.cacheReadInputTokens, 4);
      });

      test('a SAFETY finish reason reads as a refusal', () async {
        final body = StringBuffer()
          ..writeln('data: ${jsonEncode({
                'candidates': [
                  {'finishReason': 'SAFETY'},
                ],
                'usageMetadata': {'promptTokenCount': 12},
              })}')
          ..writeln();
        final b = brokerFor(body.toString());
        final turn = b.streamDetailed(
          apiKey: 'g',
          model: 'gemini-2.5-pro',
          request: request,
        );
        expect(await turn.deltas.toList(), isEmpty);
        final done = await turn.completion;
        expect(done.isRefusal, isTrue);
        expect(done.inputTokens, 12);
      });

      test('MAX_TOKENS reads as truncation', () async {
        final body = StringBuffer()
          ..writeln('data: ${jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'cut'},
                      ],
                    },
                    'finishReason': 'MAX_TOKENS',
                  },
                ],
              })}')
          ..writeln();
        final b = brokerFor(body.toString());
        final turn = b.streamDetailed(
          apiKey: 'g',
          model: 'gemini-2.5-pro',
          request: request,
        );
        await turn.deltas.toList();
        final done = await turn.completion;
        expect(done.isTruncated, isTrue);
        expect(done.model, 'gemini-2.5-pro', reason: 'falls back to requested');
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

  // Structured output. Before 0.6.0 `ChatRequest.jsonSchema` was dropped here
  // in silence and the model answered in prose — the bug that abandoned a
  // whole prompt-improvement run.
  group('GeminiBroker structured output', () {
    final broker = GeminiBroker();

    Map<String, Object?> configFor(ChatRequest request) =>
        broker.buildPayload(request)['generationConfig']!
            as Map<String, Object?>;

    test('a json schema becomes responseMimeType plus a translated schema', () {
      final config = configFor(
        const ChatRequest(
          system: 's',
          messages: [AiMessage.user('score this')],
          jsonSchema: kJudgeJsonSchema,
        ),
      );
      expect(config['responseMimeType'], 'application/json');
      expect(config['responseSchema'], toGeminiSchema(kJudgeJsonSchema));
    });

    test('no additionalProperties survives into responseSchema', () {
      final config = configFor(
        const ChatRequest(
          system: 's',
          messages: [],
          jsonSchema: kJudgeJsonSchema,
        ),
      );
      expect(
        allKeysDeep(config['responseSchema']),
        isNot(contains('additionalProperties')),
        reason: 'Gemini 400s on it — the whole reason a translation exists',
      );
    });

    test('nullable unions arrive as the nullable flag', () {
      final schema = configFor(
        const ChatRequest(
          system: 's',
          messages: [],
          jsonSchema: kJudgeJsonSchema,
        ),
      )['responseSchema']! as Map<String, Object?>;
      final properties = schema['properties']! as Map<String, Object?>;
      final prompt = properties['improved_prompt']! as Map<String, Object?>;
      expect(prompt['type'], 'string');
      expect(prompt['nullable'], isTrue);
    });

    test('neither field is sent when no schema was asked for', () {
      final config = configFor(const ChatRequest(system: 's', messages: []));
      expect(config.containsKey('responseMimeType'), isFalse);
      expect(config.containsKey('responseSchema'), isFalse);
    });

    test('an untranslatable schema still forces JSON, unconstrained', () {
      const recursive = {
        'type': 'object',
        r'$defs': {
          'node': {
            'type': 'object',
            'properties': {
              'child': {r'$ref': r'#/$defs/node'},
            },
          },
        },
        'properties': {
          'root': {r'$ref': r'#/$defs/node'},
        },
      };
      final config = configFor(
        const ChatRequest(system: 's', messages: [], jsonSchema: recursive),
      );
      expect(config['responseMimeType'], 'application/json');
      expect(
        config.containsKey('responseSchema'),
        isFalse,
        reason: 'unconstrained JSON beats both prose and a 400',
      );
    });

    test('generateContent puts it on the wire', () async {
      late Map<String, Object?> sent;
      final b = GeminiBroker(
        client: MockClient((req) async {
          sent = jsonDecode(req.body) as Map<String, Object?>;
          return Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': '{"changelog":"none"}'},
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
          messages: [AiMessage.user('score')],
          jsonSchema: kJudgeJsonSchema,
        ),
      );
      final config = sent['generationConfig']! as Map<String, Object?>;
      expect(config['responseMimeType'], 'application/json');
      expect(config['responseSchema'], toGeminiSchema(kJudgeJsonSchema));
    });

    test('streamGenerateContent sends the same generationConfig', () async {
      late Map<String, Object?> sent;
      final b = GeminiBroker(
        client: MockClient.streaming((req, bodyStream) async {
          sent = jsonDecode(await bodyStream.bytesToString())
              as Map<String, Object?>;
          return StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode('data: ${jsonEncode({
                    'candidates': [
                      {
                        'content': {
                          'parts': [
                            {'text': '{}'},
                          ],
                        },
                      },
                    ],
                  })}\n\n'),
            ),
            200,
          );
        }),
      );
      await b
          .stream(
            apiKey: 'g',
            model: 'gemini-2.5-pro',
            request: const ChatRequest(
              system: '',
              messages: [AiMessage.user('score')],
              jsonSchema: kJudgeJsonSchema,
            ),
          )
          .toList();
      final config = sent['generationConfig']! as Map<String, Object?>;
      expect(config['responseMimeType'], 'application/json');
      expect(config['responseSchema'], toGeminiSchema(kJudgeJsonSchema));
    });
  });
}
