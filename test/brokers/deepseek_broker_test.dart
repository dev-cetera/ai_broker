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
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('DeepSeekBroker', () {
    test('is a chat broker with no embeddings', () {
      final b = DeepSeekBroker();
      expect(b.id, 'deepseek');
      expect(b.label, 'DeepSeek');
      expect(b, isA<ChatBroker>());
      expect(b, isA<KeyCheckBroker>());
      expect(b, isNot(isA<EmbedBroker>()));
    });

    test('posts to api.deepseek.com with max_tokens and reasoning_effort',
        () async {
      late Request sent;
      final b = DeepSeekBroker(
        client: MockClient((req) async {
          sent = req;
          return Response(
            jsonEncode({
              'model': 'deepseek-flash',
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'hola'},
                  'finish_reason': 'stop',
                },
              ],
              'usage': {'prompt_tokens': 5, 'completion_tokens': 1},
            }),
            200,
          );
        }),
      );
      final out = await b.chat(
        apiKey: 'sk-ds',
        model: 'deepseek-flash',
        request: const ChatRequest(
          system: 's',
          messages: [AiMessage.user('u')],
          maxTokens: 300,
          effort: AiEffort.low,
        ),
      );
      expect(out, 'hola');
      expect(sent.url.toString(), 'https://api.deepseek.com/chat/completions');
      expect(sent.headers['Authorization'], 'Bearer sk-ds');
      final body = jsonDecode(sent.body) as Map<String, Object?>;
      expect(body['max_tokens'], 300);
      expect(body.containsKey('max_completion_tokens'), isFalse);
      expect(body['reasoning_effort'], 'low');
      expect(body.containsKey('temperature'), isFalse);
    });

    test('a JSON schema is sent as JSON mode, which is all DeepSeek has', () {
      final p = DeepSeekBroker().buildPayload(
        'deepseek-flash',
        const ChatRequest(
          system: '',
          messages: [AiMessage.user('u')],
          jsonSchema: {
            'type': 'object',
            'properties': {
              'a': {'type': 'string'},
            },
          },
        ),
        stream: false,
      );
      expect(p['response_format'], {'type': 'json_object'});
    });

    test('lists models from /models', () async {
      final b = DeepSeekBroker(
        client: MockClient((req) async {
          expect(req.url.toString(), 'https://api.deepseek.com/models');
          return Response(
            jsonEncode({
              'object': 'list',
              'data': [
                {'id': 'deepseek-v4-pro', 'object': 'model'},
                {'id': 'deepseek-flash', 'object': 'model'},
              ],
            }),
            200,
          );
        }),
      );
      expect(
        await b.listModels('k'),
        ['deepseek-flash', 'deepseek-v4-pro'],
      );
    });
  });
}
