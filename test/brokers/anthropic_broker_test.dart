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
                .having((e) => e.message, 'message', contains('no content')),
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
