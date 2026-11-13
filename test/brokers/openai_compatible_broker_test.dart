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

Response _json(Object body, [int status = 200]) =>
    Response(jsonEncode(body), status);

Map<String, Object?> _reply(String content) => {
      'model': 'served-model',
      'choices': [
        {
          'message': {'role': 'assistant', 'content': content},
          'finish_reason': 'stop',
        },
      ],
      'usage': {'prompt_tokens': 3, 'completion_tokens': 4},
    };

void main() {
  group('OpenAiCompatibleBroker', () {
    test('uses its own id, label and base URL, without a trailing slash',
        () async {
      late Request sent;
      final b = OpenAiCompatibleBroker(
        id: 'groq',
        label: 'Groq',
        baseUrl: 'https://api.groq.com/openai/v1/',
        client: MockClient((req) async {
          sent = req;
          return _json(_reply('hi'));
        }),
      );
      expect(b.id, 'groq');
      expect(b.label, 'Groq');
      expect(b.baseUrl, 'https://api.groq.com/openai/v1');
      final out = await b.chatWithMeta(
        apiKey: 'gsk',
        model: 'llama',
        request: const ChatRequest(
          system: 's',
          messages: [AiMessage.user('u')],
        ),
      );
      expect(
        sent.url.toString(),
        'https://api.groq.com/openai/v1/chat/completions',
      );
      expect(sent.headers['Authorization'], 'Bearer gsk');
      expect(out.text, 'hi');
      expect(out.model, 'served-model');
      expect(out.finishReason, AiFinishReason.stop);
      expect(out.inputTokens, 3);
    });

    test('sends extra headers on every request', () async {
      final seen = <Map<String, String>>[];
      final b = OpenAiCompatibleBroker(
        id: 'openrouter',
        label: 'OpenRouter',
        baseUrl: 'https://openrouter.ai/api/v1',
        extraHeaders: {'HTTP-Referer': 'https://example.com'},
        client: MockClient((req) async {
          seen.add(req.headers);
          return req.method == 'GET'
              ? _json({'data': <Object?>[]})
              : _json(_reply('x'));
        }),
      );
      await b.listModels('k');
      await b.chat(
        apiKey: 'k',
        model: 'm',
        request: const ChatRequest(system: '', messages: [AiMessage.user('u')]),
      );
      for (final h in seen) {
        expect(h['HTTP-Referer'], 'https://example.com');
        expect(h['Authorization'], 'Bearer k');
      }
    });

    test('listModels keeps every model unless a filter is given', () async {
      MockClient models() => MockClient(
            (_) async => _json({
              'data': [
                {'id': 'b-chat'},
                {'id': 'a-embed'},
              ],
            }),
          );
      final all = OpenAiCompatibleBroker(
        id: 'x',
        label: 'X',
        baseUrl: 'https://x.test/v1',
        client: models(),
      );
      expect(await all.listModels('k'), ['a-embed', 'b-chat']);
      final filtered = OpenAiCompatibleBroker(
        id: 'x',
        label: 'X',
        baseUrl: 'https://x.test/v1',
        client: models(),
        modelFilter: (id) => id.endsWith('-chat'),
      );
      expect(await filtered.listModels('k'), ['b-chat']);
    });

    group('buildPayload', () {
      final b = OpenAiCompatibleBroker(
        id: 'x',
        label: 'X',
        baseUrl: 'https://x.test/v1',
      );

      test('omits temperature unless set and uses max_tokens by default', () {
        final p = b.buildPayload(
          'm',
          const ChatRequest(system: '', messages: [AiMessage.user('u')]),
          stream: false,
        );
        expect(p.containsKey('temperature'), isFalse);
        expect(p['max_tokens'], 2048);
        expect(p.containsKey('max_completion_tokens'), isFalse);
        expect(p.containsKey('reasoning_effort'), isFalse);
      });

      test('effort becomes reasoning_effort', () {
        final p = b.buildPayload(
          'm',
          const ChatRequest(
            system: '',
            messages: [AiMessage.user('u')],
            effort: AiEffort.low,
            temperature: 0.2,
          ),
          stream: false,
        );
        expect(p['reasoning_effort'], 'low');
        expect(p['temperature'], 0.2);
      });

      test('a stream asks for usage', () {
        final p = b.buildPayload(
          'm',
          const ChatRequest(system: '', messages: [AiMessage.user('u')]),
          stream: true,
        );
        expect(p['stream'], isTrue);
        expect(p['stream_options'], {'include_usage': true});
      });

      test('streamUsage: false leaves stream_options out', () {
        final quiet = OpenAiCompatibleBroker(
          id: 'x',
          label: 'X',
          baseUrl: 'https://x.test/v1',
          streamUsage: false,
        );
        final p = quiet.buildPayload(
          'm',
          const ChatRequest(system: '', messages: [AiMessage.user('u')]),
          stream: true,
        );
        expect(p.containsKey('stream_options'), isFalse);
      });

      test('without json_schema support, a schema becomes JSON mode', () {
        final jsonOnly = OpenAiCompatibleBroker(
          id: 'x',
          label: 'X',
          baseUrl: 'https://x.test/v1',
          supportsJsonSchema: false,
        );
        const schema = {
          'type': 'object',
          'properties': {
            'meaning': {'type': 'string'},
          },
          'required': ['meaning'],
        };
        final p = jsonOnly.buildPayload(
          'm',
          const ChatRequest(
            system: 'Explain the word.',
            messages: [AiMessage.user('hidalgo')],
            jsonSchema: schema,
          ),
          stream: false,
        );
        expect(p['response_format'], {'type': 'json_object'});
        final system =
            (p['messages']! as List<Object?>).first! as Map<String, Object?>;
        expect(system['role'], 'system');
        final content = system['content']! as String;
        expect(content, startsWith('Explain the word.'));
        expect(content, contains('JSON'));
        expect(content, contains(jsonEncode(schema)));
      });
    });

    group('checkKey', () {
      OpenAiCompatibleBroker answering(Response Function(Request) reply) =>
          OpenAiCompatibleBroker(
            id: 'x',
            label: 'X',
            baseUrl: 'https://x.test/v1',
            client: MockClient((req) async => reply(req)),
          );

      test('200 on /models is a valid key', () async {
        late Request sent;
        final b = answering((req) {
          sent = req;
          return _json({'data': <Object?>[]});
        });
        final check = await b.checkKey('k');
        expect(check.status, AiKeyStatus.valid);
        expect(check.isValid, isTrue);
        expect(sent.method, 'GET');
        expect(sent.url.toString(), 'https://x.test/v1/models');
      });

      test('401 is an invalid key, with the provider message', () async {
        final b = answering(
          (_) => _json(
            {
              'error': {'message': 'Incorrect API key provided'},
            },
            401,
          ),
        );
        final check = await b.checkKey('bad');
        expect(check.status, AiKeyStatus.invalid);
        expect(check.statusCode, 401);
        expect(check.message, 'Incorrect API key provided');
      });

      test('402 is an error, not an invalid key', () async {
        final b = answering(
          (_) => _json(
            {
              'error': {'message': 'Insufficient Balance'},
            },
            402,
          ),
        );
        final check = await b.checkKey('k');
        expect(check.status, AiKeyStatus.error);
        expect(check.message, 'Insufficient Balance');
      });

      test('5xx means the provider could not be reached', () async {
        final b = answering((_) => Response('down', 503));
        expect((await b.checkKey('k')).status, AiKeyStatus.unreachable);
      });

      test('a network failure is unreachable', () async {
        final b = OpenAiCompatibleBroker(
          id: 'x',
          label: 'X',
          baseUrl: 'https://x.test/v1',
          client: MockClient((_) async => throw ClientException('offline')),
        );
        final check = await b.checkKey('k');
        expect(check.status, AiKeyStatus.unreachable);
        expect(check.message, 'offline');
      });

      test('an empty key is invalid without a request', () async {
        var called = false;
        final b = answering((_) {
          called = true;
          return _json({});
        });
        expect((await b.checkKey('  ')).status, AiKeyStatus.invalid);
        expect(called, isFalse);
      });
    });
  });
}
