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

import 'dart:convert';

import 'package:ai_broker/ai_broker.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../support/judge_schema.dart';

/// Guards the request shape against the parameters current Claude models
/// reject. Each of these was a 400 in production before 0.4.0.
void main() {
  group('AnthropicBroker request shape', () {
    final broker = AnthropicBroker();

    test('omits temperature unless the caller asked for one', () {
      final payload = broker.buildPayload(
        'claude-opus-5',
        const ChatRequest(system: 's', messages: [], maxTokens: 100),
        stream: false,
      );
      expect(
        payload.containsKey('temperature'),
        isFalse,
        reason:
            'temperature is rejected by Opus 5 / Sonnet 5 / the 4.6+ family',
      );
      expect(payload.containsKey('top_p'), isFalse);
    });

    test('includes temperature when explicitly set, for older models', () {
      final payload = broker.buildPayload(
        'claude-3-5-sonnet',
        const ChatRequest(system: 's', messages: [], temperature: 0.7),
        stream: false,
      );
      expect(payload['temperature'], 0.7);
    });

    test('effort maps into output_config, not the top level', () {
      final payload = broker.buildPayload(
        'claude-opus-5',
        const ChatRequest(system: 's', messages: [], effort: AiEffort.low),
        stream: false,
      );
      expect(payload['output_config'], {'effort': 'low'});
      expect(payload.containsKey('effort'), isFalse);
    });

    test('a json schema becomes output_config.format', () {
      const schema = {
        'type': 'object',
        'additionalProperties': false,
        'required': ['verdict'],
        'properties': {
          'verdict': {
            'type': 'string',
            'enum': ['PASS', 'FAIL'],
          },
        },
      };
      final payload = broker.buildPayload(
        'claude-opus-5',
        const ChatRequest(
          system: 's',
          messages: [],
          jsonSchema: schema,
          effort: AiEffort.high,
        ),
        stream: false,
      );
      final oc = payload['output_config']! as Map<String, Object?>;
      expect(oc['effort'], 'high');
      expect(oc['format'], {'type': 'json_schema', 'schema': schema});
    });

    // 0.6.0 taught GeminiBroker and OpenAiBroker to honour
    // `ChatRequest.jsonSchema`, each in its own dialect. Anthropic already
    // spoke plain JSON Schema, so its wire shape must not have moved.
    test('the judge schema is forwarded verbatim, untranslated', () {
      final payload = broker.buildPayload(
        'claude-opus-5',
        const ChatRequest(
          system: 's',
          messages: [],
          jsonSchema: kJudgeJsonSchema,
        ),
        stream: false,
      );
      final format = (payload['output_config']!
          as Map<String, Object?>)['format']! as Map<String, Object?>;
      expect(format, {'type': 'json_schema', 'schema': kJudgeJsonSchema});
      expect(
        identical(format['schema'], kJudgeJsonSchema),
        isTrue,
        reason: 'not even a defensive copy — the schema goes through as given',
      );
      // Neither of the rewrites the other two providers need happened here:
      // `additionalProperties` survives (Gemini strips it) and the nullable
      // unions stay unions (Gemini turns them into a `nullable` flag).
      expect(allKeysDeep(format['schema']), contains('additionalProperties'));
      expect(allKeysDeep(format['schema']), isNot(contains('nullable')));
      final properties = (format['schema']!
          as Map<String, Object?>)['properties']! as Map<String, Object?>;
      expect(
        (properties['improved_prompt']! as Map<String, Object?>)['type'],
        ['string', 'null'],
      );
    });

    test('the streaming payload carries the same untranslated schema', () {
      final streamed = broker.buildPayload(
        'claude-opus-5',
        const ChatRequest(
          system: 's',
          messages: [],
          jsonSchema: kJudgeJsonSchema,
        ),
        stream: true,
      );
      expect(streamed['stream'], isTrue);
      expect(
        (streamed['output_config']! as Map<String, Object?>)['format'],
        {'type': 'json_schema', 'schema': kJudgeJsonSchema},
      );
      expect(streamed.containsKey('response_format'), isFalse);
      expect(streamed.containsKey('generationConfig'), isFalse);
    });

    test('output_config is absent entirely when nothing needs it', () {
      final payload = broker.buildPayload(
        'claude-opus-5',
        const ChatRequest(system: 's', messages: []),
        stream: false,
      );
      expect(payload.containsKey('output_config'), isFalse);
    });

    test('cacheSystem turns the system prompt into a cache-marked block', () {
      final plain = broker.buildPayload(
        'claude-opus-5',
        const ChatRequest(system: 'knowledge', messages: []),
        stream: false,
      );
      expect(plain['system'], 'knowledge');

      final cached = broker.buildPayload(
        'claude-opus-5',
        const ChatRequest(system: 'knowledge', messages: [], cacheSystem: true),
        stream: false,
      );
      expect(cached['system'], [
        {
          'type': 'text',
          'text': 'knowledge',
          'cache_control': {'type': 'ephemeral'},
        },
      ]);
    });

    test('never emits a trailing assistant turn (prefill is rejected)', () {
      final payload = broker.buildPayload(
        'claude-opus-5',
        const ChatRequest(
          system: 's',
          messages: [AiMessage.user('hi'), AiMessage.assistant('there')],
        ),
        stream: false,
      );
      // The broker passes messages through verbatim; this test documents that
      // it adds nothing of its own after the caller's last turn.
      final messages = payload['messages']! as List<Object?>;
      expect(messages.length, 2);
      expect((messages.last as Map)['role'], 'assistant');
    });
  });

  group('AnthropicBroker.chatDetailed', () {
    test('reports usage, model and stop reason', () async {
      final broker = AnthropicBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'model': 'claude-opus-5',
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'text', 'text': 'hello '},
                {'type': 'text', 'text': 'world'},
              ],
              'usage': {
                'input_tokens': 812,
                'output_tokens': 12,
                'cache_read_input_tokens': 700,
                'cache_creation_input_tokens': 0,
              },
            }),
            200,
          ),
        ),
      );
      final result = await broker.chatDetailed(
        apiKey: 'k',
        model: 'claude-opus-5',
        request: const ChatRequest(system: 's', messages: []),
      );
      expect(result.text, 'hello world');
      expect(result.model, 'claude-opus-5');
      expect(result.stopReason, AiStopReason.endTurn);
      expect(result.inputTokens, 812);
      expect(result.outputTokens, 12);
      expect(result.cacheReadInputTokens, 700);
      expect(result.isRefusal, isFalse);
    });

    test('a refusal is a completion, not an exception', () async {
      final broker = AnthropicBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'model': 'claude-opus-5',
              'stop_reason': 'refusal',
              'content': <Object?>[],
              'usage': {'input_tokens': 10, 'output_tokens': 0},
            }),
            200,
          ),
        ),
      );
      final result = await broker.chatDetailed(
        apiKey: 'k',
        model: 'claude-opus-5',
        request: const ChatRequest(system: 's', messages: []),
      );
      expect(result.isRefusal, isTrue);
      expect(result.text, isEmpty);
    });

    test('max_tokens truncation is reported rather than hidden', () async {
      final broker = AnthropicBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'stop_reason': 'max_tokens',
              'content': [
                {'type': 'text', 'text': 'cut off mid-'},
              ],
              'usage': {'input_tokens': 1, 'output_tokens': 1},
            }),
            200,
          ),
        ),
      );
      final result = await broker.chatDetailed(
        apiKey: 'k',
        model: 'claude-opus-5',
        request: const ChatRequest(system: 's', messages: []),
      );
      expect(result.isTruncated, isTrue);
    });
  });

  group('AnthropicBroker.baseUrl', () {
    test('defaults to the real API', () {
      expect(AnthropicBroker().baseUrl, AnthropicBroker.defaultBaseUrl);
    });

    test('an explicit base url is used for requests', () async {
      Uri? seen;
      final broker = AnthropicBroker(
        baseUrl: 'http://127.0.0.1:8787/v1',
        client: MockClient((req) async {
          seen = req.url;
          return Response(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': 'ok'},
              ],
              'stop_reason': 'end_turn',
              'usage': <String, Object?>{},
            }),
            200,
          );
        }),
      );
      await broker.chat(
        apiKey: 'k',
        model: 'm',
        request: const ChatRequest(system: 's', messages: []),
      );
      expect(seen.toString(), 'http://127.0.0.1:8787/v1/messages');
    });
  });

  group('AiEffort / AiStopReason', () {
    test('effort wire values match the API vocabulary', () {
      expect(
        AiEffort.values.map((e) => e.wire),
        ['low', 'medium', 'high', 'xhigh', 'max'],
      );
    });

    test('an unrecognised stop reason degrades to unknown', () {
      expect(AiStopReason.fromWire('something_new'), AiStopReason.unknown);
      expect(AiStopReason.fromWire(null), AiStopReason.unknown);
      expect(AiStopReason.fromWire('refusal'), AiStopReason.refusal);
    });
  });
}
