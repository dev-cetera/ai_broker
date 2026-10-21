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
  });

  group('GeminiBroker.completeWithMeta', () {
    GeminiBroker brokerReplying(Map<String, Object?> body) => GeminiBroker(
          client: MockClient((_) async => Response(jsonEncode(body), 200)),
        );

    Map<String, Object?> reply(String text, String? finishReason) => {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': text},
                ],
              },
              if (finishReason != null) 'finishReason': finishReason,
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 12,
            'candidatesTokenCount': 34,
            'thoughtsTokenCount': 5,
            'totalTokenCount': 51,
          },
        };

    Future<AiCompletion> run(GeminiBroker b) => b.completeWithMeta(
          apiKey: 'g',
          model: 'gemini-2.5-flash',
          system: 's',
          user: 'u',
        );

    test('carries text, finish reason and usage counts', () async {
      final out = await run(brokerReplying(reply('{"a":1}', 'STOP')));
      expect(out.text, '{"a":1}');
      expect(out.rawFinishReason, 'STOP');
      expect(out.finishReason, AiFinishReason.stop);
      expect(out.inputTokens, 12);
      // Gemini reports thinking apart from the reply; outputTokens counts
      // both, the way the other providers do.
      expect(out.outputTokens, 39);
      expect(out.thinkingTokens, 5);
    });

    test('maps every documented Gemini finish reason', () async {
      const expected = <String, AiFinishReason?>{
        'STOP': AiFinishReason.stop,
        'MAX_TOKENS': AiFinishReason.maxTokens,
        'SAFETY': AiFinishReason.safety,
        'BLOCKLIST': AiFinishReason.safety,
        'PROHIBITED_CONTENT': AiFinishReason.safety,
        'SPII': AiFinishReason.safety,
        'IMAGE_SAFETY': AiFinishReason.safety,
        'IMAGE_PROHIBITED_CONTENT': AiFinishReason.safety,
        'RECITATION': AiFinishReason.recitation,
        'IMAGE_RECITATION': AiFinishReason.recitation,
        'LANGUAGE': AiFinishReason.unsupportedLanguage,
        'MALFORMED_FUNCTION_CALL': AiFinishReason.toolCallError,
        'UNEXPECTED_TOOL_CALL': AiFinishReason.toolCallError,
        'TOO_MANY_TOOL_CALLS': AiFinishReason.toolCallError,
        // Gemini's own "we don't know" values stay unmapped: the raw
        // string is carried, the normalised field is null.
        'OTHER': null,
        'IMAGE_OTHER': null,
        'FINISH_REASON_UNSPECIFIED': null,
        'SOMETHING_NEW': null,
      };
      for (final entry in expected.entries) {
        final out = await run(brokerReplying(reply('x', entry.key)));
        expect(out.rawFinishReason, entry.key);
        expect(out.finishReason, entry.value, reason: entry.key);
      }
    });

    test('leaves the reason and counts null when Gemini omits them', () async {
      final out = await run(
        brokerReplying({
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
      );
      expect(out.rawFinishReason, isNull);
      expect(out.finishReason, isNull);
      expect(out.inputTokens, isNull);
      expect(out.outputTokens, isNull);
      expect(out.thinkingTokens, isNull);
    });

    test('names the finish reason when a truncated reply has no text',
        () async {
      await expectLater(
        run(brokerReplying(reply('', 'MAX_TOKENS'))),
        throwsA(
          isA<AiBrokerException>()
              .having((e) => e.message, 'message', contains('MAX_TOKENS')),
        ),
      );
    });

    test('complete returns the same text as completeWithMeta', () async {
      final b = brokerReplying(reply('same', 'MAX_TOKENS'));
      final text = await b.complete(
        apiKey: 'g',
        model: 'gemini-2.5-flash',
        system: 's',
        user: 'u',
      );
      expect(text, 'same');
    });
  });
}
