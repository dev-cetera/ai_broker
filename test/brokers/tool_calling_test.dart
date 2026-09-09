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

// Tool calling across all three chat providers, in one file on purpose: the
// capability is identical from the caller's side and the wire shape is
// different everywhere, so the three groups below are best read side by side.
//
// Each provider covers the same five things — how tools are declared, one
// call, several calls in a single turn, results fed back into the next
// request, and what streaming does with arguments that arrive in fragments.

import 'dart:convert';

import 'package:ai_broker/ai_broker.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  _thoughtSignatureTests();
  // ---------------------------------------------------------------------------
  // Anthropic
  // ---------------------------------------------------------------------------

  group('AnthropicBroker tool calling', () {
    test('declares tools flat, and spells `required` as `any`', () {
      final b = AnthropicBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      final payload = b.buildPayload(
        'claude-opus-4-7',
        const ChatRequest(
          system: '',
          messages: [AiMessage.user('weather?')],
          tools: [weatherTool, timeTool],
          toolChoice: AiToolChoice.required,
        ),
        stream: false,
      );
      expect(payload['tools'], [
        {
          'name': 'get_weather',
          'description': 'Look up the current weather for a city.',
          'input_schema': weatherSchema,
        },
        {
          'name': 'get_time',
          'description': 'Look up the current local time for a city.',
          'input_schema': weatherSchema,
        },
      ]);
      // An object, not a string — and `any`, not `required`.
      expect(payload['tool_choice'], {'type': 'any'});
    });

    test('maps auto and none straight through', () {
      final b = AnthropicBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      Object? choiceFor(AiToolChoice choice) => b.buildPayload(
            'm',
            ChatRequest(
              system: '',
              messages: const [],
              tools: const [weatherTool],
              toolChoice: choice,
            ),
            stream: false,
          )['tool_choice'];
      expect(choiceFor(AiToolChoice.auto), {'type': 'auto'});
      expect(choiceFor(AiToolChoice.none), {'type': 'none'});
    });

    test('sends no tool fields when the request declares none', () {
      final b = AnthropicBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      final payload = b.buildPayload(
        'm',
        const ChatRequest(
          system: '',
          messages: [AiMessage.user('hi')],
          // A choice with nothing to choose from is a 400; it must not be sent.
          toolChoice: AiToolChoice.required,
        ),
        stream: false,
      );
      expect(payload.containsKey('tools'), isFalse);
      expect(payload.containsKey('tool_choice'), isFalse);
      // Plain turns keep the string-content shorthand.
      expect(payload['messages'], [
        {'role': 'user', 'content': 'hi'},
      ]);
    });

    test('reads a single tool_use block alongside the text', () async {
      final b = AnthropicBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'model': 'claude-opus-4-7',
              'stop_reason': 'tool_use',
              'content': [
                {'type': 'text', 'text': 'Let me check.'},
                {
                  'type': 'tool_use',
                  'id': 'toolu_01',
                  'name': 'get_weather',
                  'input': {'city': 'Canberra'},
                },
              ],
              'usage': {'input_tokens': 42, 'output_tokens': 9},
            }),
            200,
          ),
        ),
      );
      final done = await b.chatDetailed(
        apiKey: 'k',
        model: 'claude-opus-4-7',
        request: const ChatRequest(
          system: '',
          messages: [AiMessage.user('weather?')],
          tools: [weatherTool],
        ),
      );
      expect(done.text, 'Let me check.');
      expect(done.stopReason, AiStopReason.toolUse);
      expect(done.wantsTool, isTrue);
      expect(done.toolCalls, hasLength(1));
      expect(done.toolCalls.single.id, 'toolu_01');
      expect(done.toolCalls.single.name, 'get_weather');
      expect(done.toolCalls.single.arguments, {'city': 'Canberra'});
      expect(done.inputTokens, 42);
    });

    test('reads every tool_use block when one turn asks for several', () async {
      final b = AnthropicBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'stop_reason': 'tool_use',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'toolu_01',
                  'name': 'get_weather',
                  'input': {'city': 'Canberra'},
                },
                {
                  'type': 'tool_use',
                  'id': 'toolu_02',
                  'name': 'get_time',
                  'input': {'city': 'Atlanta'},
                },
              ],
            }),
            200,
          ),
        ),
      );
      final done = await b.chatDetailed(
        apiKey: 'k',
        model: 'm',
        request: const ChatRequest(system: '', messages: []),
      );
      expect(done.text, isEmpty);
      expect(
        done.toolCalls.map((c) => c.name),
        ['get_weather', 'get_time'],
      );
      expect(done.toolCalls.last.arguments, {'city': 'Atlanta'});
    });

    test('returns every result for a turn in ONE user message', () async {
      late Map<String, Object?> sentBody;
      final b = AnthropicBroker(
        client: MockClient((req) async {
          sentBody = jsonDecode(req.body) as Map<String, Object?>;
          return Response(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': 'done'},
              ],
            }),
            200,
          );
        }),
      );
      await b.chatDetailed(
        apiKey: 'k',
        model: 'm',
        request: const ChatRequest(
          system: '',
          messages: twoCallHistory,
          tools: [weatherTool, timeTool],
        ),
      );
      final messages = sentBody['messages'] as List<Object?>;
      // Three, not four: the two results are one message. Splitting them is a
      // 400 — this is the assertion that pins that down.
      expect(messages, hasLength(3));
      expect(messages[0], {'role': 'user', 'content': 'weather and time?'});
      expect(messages[1], {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Checking both.'},
          {
            'type': 'tool_use',
            'id': 'toolu_01',
            'name': 'get_weather',
            'input': {'city': 'Canberra'},
          },
          {
            'type': 'tool_use',
            'id': 'toolu_02',
            'name': 'get_time',
            'input': {'city': 'Atlanta'},
          },
        ],
      });
      expect(messages[2], {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_01',
            'content': '18C and clear',
          },
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_02',
            'content': '9:04am',
          },
        ],
      });
    });

    test('flags a failed result with is_error, and only then', () {
      final b = AnthropicBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      final payload = b.buildPayload(
        'm',
        const ChatRequest(
          system: '',
          messages: [
            AiMessage.toolResult(
              toolCallId: 'toolu_01',
              content: 'upstream timed out',
              isError: true,
            ),
            AiMessage.toolResult(toolCallId: 'toolu_02', content: 'ok'),
          ],
        ),
        stream: false,
      );
      final blocks = (payload['messages']! as List<Object?>).single;
      expect((blocks! as Map<String, Object?>)['content'], [
        {
          'type': 'tool_result',
          'tool_use_id': 'toolu_01',
          'content': 'upstream timed out',
          'is_error': true,
        },
        {
          'type': 'tool_result',
          'tool_use_id': 'toolu_02',
          'content': 'ok',
        },
      ]);
    });

    test('streams text unchanged while assembling argument fragments',
        () async {
      final wire = StringBuffer()
        ..write(
          _sse('message_start', {
            'message': {
              'model': 'claude-opus-4-7',
              'usage': {'input_tokens': 12},
            },
          }),
        )
        ..write(
          _sse('content_block_delta', {
            'index': 0,
            'delta': {'type': 'text_delta', 'text': 'Checking '},
          }),
        )
        ..write(
          _sse('content_block_delta', {
            'index': 0,
            'delta': {'type': 'text_delta', 'text': 'now.'},
          }),
        )
        ..write(
          _sse('content_block_start', {
            'index': 1,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_01',
              'name': 'get_weather',
              'input': <String, Object?>{},
            },
          }),
        )
        // The arguments arrive as JSON fragments — neither half parses alone.
        ..write(
          _sse('content_block_delta', {
            'index': 1,
            'delta': {'type': 'input_json_delta', 'partial_json': '{"city":'},
          }),
        )
        ..write(
          _sse('content_block_delta', {
            'index': 1,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '"Canberra"}',
            },
          }),
        )
        ..write(_sse('content_block_stop', {'index': 1}))
        ..write(
          _sse('message_delta', {
            'delta': {'stop_reason': 'tool_use'},
            'usage': {'output_tokens': 31},
          }),
        )
        ..write(_sse('message_stop', const {}));
      final b = AnthropicBroker(
        client: MockClient.streaming(
          (_, __) async => StreamedResponse(
            Stream<List<int>>.value(utf8.encode(wire.toString())),
            200,
          ),
        ),
      );
      final turn = b.streamDetailed(
        apiKey: 'k',
        model: 'claude-opus-4-7',
        request: const ChatRequest(
          system: '',
          messages: [],
          tools: [weatherTool],
        ),
      );
      // Text deltas are untouched by any of this.
      expect(await turn.deltas.toList(), ['Checking ', 'now.']);
      final done = await turn.completion;
      expect(done.stopReason, AiStopReason.toolUse);
      expect(done.toolCalls, hasLength(1));
      expect(done.toolCalls.single.id, 'toolu_01');
      expect(done.toolCalls.single.name, 'get_weather');
      expect(done.toolCalls.single.arguments, {'city': 'Canberra'});
      expect(done.outputTokens, 31);
    });

    test('streams two interleaved calls into two results', () async {
      final wire = StringBuffer()
        ..write(
          _sse('content_block_start', {
            'index': 0,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_01',
              'name': 'get_weather',
            },
          }),
        )
        ..write(
          _sse('content_block_start', {
            'index': 1,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_02',
              'name': 'get_time',
            },
          }),
        )
        // Out of order on purpose: the block index is what keys them, not
        // arrival order.
        ..write(
          _sse('content_block_delta', {
            'index': 1,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '{"city":"Atlanta"}',
            },
          }),
        )
        ..write(
          _sse('content_block_delta', {
            'index': 0,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '{"city":"Canberra"}',
            },
          }),
        )
        ..write(_sse('message_stop', const {}));
      final b = AnthropicBroker(
        client: MockClient.streaming(
          (_, __) async => StreamedResponse(
            Stream<List<int>>.value(utf8.encode(wire.toString())),
            200,
          ),
        ),
      );
      final turn = b.streamDetailed(
        apiKey: 'k',
        model: 'm',
        request: const ChatRequest(system: '', messages: []),
      );
      expect(await turn.deltas.toList(), isEmpty);
      final done = await turn.completion;
      expect(done.toolCalls.map((c) => c.name), ['get_weather', 'get_time']);
      expect(done.toolCalls.first.arguments, {'city': 'Canberra'});
      expect(done.toolCalls.last.arguments, {'city': 'Atlanta'});
    });

    test('chat() names the method that can return a tool call', () async {
      final b = AnthropicBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'stop_reason': 'tool_use',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'toolu_01',
                  'name': 'get_weather',
                  'input': <String, Object?>{},
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
          model: 'm',
          request: const ChatRequest(system: '', messages: []),
        ),
        throwsA(
          isA<AiBrokerException>().having(
            (e) => e.message,
            'message',
            allOf(contains('chatDetailed'), contains('get_weather')),
          ),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Gemini
  // ---------------------------------------------------------------------------

  group('GeminiBroker tool calling', () {
    test('nests every declaration under one functionDeclarations entry', () {
      final b = GeminiBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      final payload = b.buildPayload(
        const ChatRequest(
          system: '',
          messages: [AiMessage.user('weather?')],
          tools: [weatherTool, timeTool],
          toolChoice: AiToolChoice.required,
        ),
      );
      // One `tools` entry holding both, not one entry per tool.
      expect(payload['tools'], [
        {
          'functionDeclarations': [
            {
              'name': 'get_weather',
              'description': 'Look up the current weather for a city.',
              // Translated, not forwarded: `additionalProperties` is a 400.
              'parameters': {
                'type': 'object',
                'required': ['city'],
                'properties': {
                  'city': {'type': 'string', 'description': 'City name'},
                },
              },
            },
            {
              'name': 'get_time',
              'description': 'Look up the current local time for a city.',
              'parameters': {
                'type': 'object',
                'required': ['city'],
                'properties': {
                  'city': {'type': 'string', 'description': 'City name'},
                },
              },
            },
          ],
        },
      ]);
      expect(payload['toolConfig'], {
        'functionCallingConfig': {'mode': 'ANY'},
      });
    });

    test('maps auto and none to Gemini modes', () {
      final b = GeminiBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      Object? modeFor(AiToolChoice choice) => b.buildPayload(
            ChatRequest(
              system: '',
              messages: const [],
              tools: const [weatherTool],
              toolChoice: choice,
            ),
          )['toolConfig'];
      expect(modeFor(AiToolChoice.auto), {
        'functionCallingConfig': {'mode': 'AUTO'},
      });
      expect(modeFor(AiToolChoice.none), {
        'functionCallingConfig': {'mode': 'NONE'},
      });
    });

    test('sends no tool fields when the request declares none', () {
      final b = GeminiBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      final payload = b.buildPayload(
        const ChatRequest(
          system: '',
          messages: [AiMessage.user('hi')],
          toolChoice: AiToolChoice.auto,
        ),
      );
      expect(payload.containsKey('tools'), isFalse);
      expect(payload.containsKey('toolConfig'), isFalse);
      expect(payload['contents'], [
        {
          'role': 'user',
          'parts': [
            {'text': 'hi'},
          ],
        },
      ]);
    });

    test('reads a functionCall part and synthesises a stable id', () async {
      final b = GeminiBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'modelVersion': 'gemini-2.5-pro-002',
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'functionCall': {
                          'name': 'get_weather',
                          'args': {'city': 'Canberra'},
                        },
                      },
                    ],
                  },
                  // Gemini says STOP even here — it has no tool finish reason.
                  'finishReason': 'STOP',
                },
              ],
              'usageMetadata': {
                'promptTokenCount': 20,
                'candidatesTokenCount': 5,
              },
            }),
            200,
          ),
        ),
      );
      final done = await b.chatDetailed(
        apiKey: 'g',
        model: 'gemini-2.5-pro',
        request: const ChatRequest(
          system: '',
          messages: [AiMessage.user('weather?')],
          tools: [weatherTool],
        ),
      );
      expect(done.text, isEmpty);
      // Normalised from the calls, because the wire never says `tool_use`.
      expect(done.stopReason, AiStopReason.toolUse);
      expect(done.toolCalls, hasLength(1));
      expect(done.toolCalls.single.id, 'call_0_get_weather');
      expect(
        done.toolCalls.single.id,
        GeminiBroker.syntheticToolCallId(0, 'get_weather'),
      );
      expect(done.toolCalls.single.arguments, {'city': 'Canberra'});
      expect(done.model, 'gemini-2.5-pro-002');
      expect(done.inputTokens, 20);
    });

    test('reads several functionCall parts from one turn', () async {
      final b = GeminiBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Checking both.'},
                      {
                        'functionCall': {
                          'name': 'get_weather',
                          'args': {'city': 'Canberra'},
                        },
                      },
                      {
                        'functionCall': {
                          'name': 'get_time',
                          'args': {'city': 'Atlanta'},
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
      final done = await b.chatDetailed(
        apiKey: 'g',
        model: 'm',
        request: const ChatRequest(system: '', messages: []),
      );
      expect(done.text, 'Checking both.');
      expect(done.toolCalls.map((c) => c.id), [
        'call_0_get_weather',
        'call_1_get_time',
      ]);
      expect(done.toolCalls.last.arguments, {'city': 'Atlanta'});
    });

    test('feeds results back as functionResponse parts, coalesced', () async {
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
                      {'text': 'done'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      await b.chatDetailed(
        apiKey: 'g',
        model: 'm',
        request: const ChatRequest(
          system: '',
          messages: geminiTwoCallHistory,
          tools: [weatherTool, timeTool],
        ),
      );
      expect(sentBody['contents'], [
        {
          'role': 'user',
          'parts': [
            {'text': 'weather and time?'},
          ],
        },
        {
          'role': 'model',
          'parts': [
            {'text': 'Checking both.'},
            {
              'functionCall': {
                'name': 'get_weather',
                'args': {'city': 'Canberra'},
              },
            },
            {
              'functionCall': {
                'name': 'get_time',
                'args': {'city': 'Atlanta'},
              },
            },
          ],
        },
        {
          'role': 'user',
          'parts': [
            // Keyed by name, which is recovered from the assistant turn — the
            // wire format has no id to quote back.
            {
              'functionResponse': {
                'name': 'get_weather',
                'response': {'result': '18C and clear'},
              },
            },
            {
              'functionResponse': {
                'name': 'get_time',
                'response': {'result': '9:04am'},
              },
            },
          ],
        },
      ]);
    });

    test('recovers the name from the id when the call turn is absent', () {
      final b = GeminiBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      final payload = b.buildPayload(
        const ChatRequest(
          system: '',
          messages: [
            AiMessage.toolResult(
              toolCallId: 'call_7_get_weather',
              content: 'nope',
              isError: true,
            ),
          ],
        ),
      );
      expect(payload['contents'], [
        {
          'role': 'user',
          'parts': [
            {
              'functionResponse': {
                'name': 'get_weather',
                // No `is_error` field exists here; the key says it instead.
                'response': {'error': 'nope'},
              },
            },
          ],
        },
      ]);
    });

    test('collects functionCall parts from the stream', () async {
      final wire = StringBuffer()
        ..write(
          _data({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'Checking.'},
                  ],
                },
              },
            ],
          }),
        )
        ..write(
          _data({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'functionCall': {
                        'name': 'get_weather',
                        'args': {'city': 'Canberra'},
                      },
                    },
                    {
                      'functionCall': {
                        'name': 'get_time',
                        'args': {'city': 'Atlanta'},
                      },
                    },
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
          }),
        );
      final b = GeminiBroker(
        client: MockClient.streaming(
          (_, __) async => StreamedResponse(
            Stream<List<int>>.value(utf8.encode(wire.toString())),
            200,
          ),
        ),
      );
      final turn = b.streamDetailed(
        apiKey: 'g',
        model: 'gemini-2.5-pro',
        request: const ChatRequest(
          system: '',
          messages: [],
          tools: [weatherTool, timeTool],
        ),
      );
      expect(await turn.deltas.toList(), ['Checking.']);
      final done = await turn.completion;
      expect(done.stopReason, AiStopReason.toolUse);
      expect(done.toolCalls.map((c) => c.id), [
        'call_0_get_weather',
        'call_1_get_time',
      ]);
      expect(done.toolCalls.first.arguments, {'city': 'Canberra'});
    });

    test('chat() names the method that can return a tool call', () async {
      final b = GeminiBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'functionCall': {
                          'name': 'get_weather',
                          'args': <String, Object?>{},
                        },
                      },
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
          isA<AiBrokerException>().having(
            (e) => e.message,
            'message',
            allOf(contains('chatDetailed'), contains('get_weather')),
          ),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // OpenAI
  // ---------------------------------------------------------------------------

  group('OpenAiBroker tool calling', () {
    test('wraps every tool in a function envelope', () {
      final b = OpenAiBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      final payload = b.buildPayload(
        'gpt-4o',
        const ChatRequest(
          system: '',
          messages: [AiMessage.user('weather?')],
          tools: [weatherTool, timeTool],
          toolChoice: AiToolChoice.required,
        ),
        stream: false,
      );
      expect(payload['tools'], [
        {
          'type': 'function',
          'function': {
            'name': 'get_weather',
            'description': 'Look up the current weather for a city.',
            'parameters': weatherSchema,
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'get_time',
            'description': 'Look up the current local time for a city.',
            'parameters': weatherSchema,
          },
        },
      ]);
      // A bare string here, where Anthropic wants an object.
      expect(payload['tool_choice'], 'required');
    });

    test('maps auto and none straight through', () {
      final b = OpenAiBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      Object? choiceFor(AiToolChoice choice) => b.buildPayload(
            'm',
            ChatRequest(
              system: '',
              messages: const [],
              tools: const [weatherTool],
              toolChoice: choice,
            ),
            stream: false,
          )['tool_choice'];
      expect(choiceFor(AiToolChoice.auto), 'auto');
      expect(choiceFor(AiToolChoice.none), 'none');
    });

    test('sends no tool fields when the request declares none', () {
      final b = OpenAiBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      final payload = b.buildPayload(
        'm',
        const ChatRequest(
          system: 'sys',
          messages: [AiMessage.user('hi')],
          toolChoice: AiToolChoice.required,
        ),
        stream: false,
      );
      expect(payload.containsKey('tools'), isFalse);
      expect(payload.containsKey('tool_choice'), isFalse);
      expect(payload['messages'], [
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'hi'},
      ]);
    });

    test('parses the JSON-string arguments into a map', () async {
      final b = OpenAiBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'model': 'gpt-4o-2024-08-06',
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'role': 'assistant',
                    'content': null,
                    'tool_calls': [
                      {
                        'id': 'call_abc',
                        'type': 'function',
                        'function': {
                          'name': 'get_weather',
                          // A string, not an object. This is the trap.
                          'arguments': '{"city":"Atlanta","days":3}',
                        },
                      },
                    ],
                  },
                },
              ],
              'usage': {'prompt_tokens': 55, 'completion_tokens': 12},
            }),
            200,
          ),
        ),
      );
      final done = await b.chatDetailed(
        apiKey: 'k',
        model: 'gpt-4o',
        request: const ChatRequest(
          system: '',
          messages: [AiMessage.user('weather?')],
          tools: [weatherTool],
        ),
      );
      expect(done.text, isEmpty);
      expect(done.stopReason, AiStopReason.toolUse);
      expect(done.toolCalls, hasLength(1));
      expect(done.toolCalls.single.id, 'call_abc');
      expect(done.toolCalls.single.name, 'get_weather');
      // Decoded, and typed — not a string anyone has to re-parse.
      expect(done.toolCalls.single.arguments, {'city': 'Atlanta', 'days': 3});
      expect(done.toolCalls.single.arguments['days'], isA<int>());
      expect(done.model, 'gpt-4o-2024-08-06');
      expect(done.inputTokens, 55);
      expect(done.outputTokens, 12);
    });

    test('parses arguments whose values contain JSON-looking text', () async {
      // The case a substring match gets wrong: the value itself holds braces
      // and escaped quotes.
      const raw = r'{"query":"{\"city\":\"Atlanta\"}","limit":2}';
      final b = OpenAiBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'tool_calls': [
                      {
                        'id': 'call_abc',
                        'function': {'name': 'search', 'arguments': raw},
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
      final done = await b.chatDetailed(
        apiKey: 'k',
        model: 'm',
        request: const ChatRequest(system: '', messages: []),
      );
      expect(done.toolCalls.single.arguments, {
        'query': '{"city":"Atlanta"}',
        'limit': 2,
      });
    });

    test('surfaces a call whose arguments string is unparseable', () async {
      final b = OpenAiBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'tool_calls': [
                      {
                        'id': 'call_abc',
                        'function': {
                          'name': 'get_weather',
                          'arguments': '{"city":',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
      final done = await b.chatDetailed(
        apiKey: 'k',
        model: 'm',
        request: const ChatRequest(system: '', messages: []),
      );
      // The call is still reported — the caller validates before executing.
      expect(done.toolCalls.single.name, 'get_weather');
      expect(done.toolCalls.single.arguments, isEmpty);
    });

    test('reads every tool_call when one turn asks for several', () async {
      final b = OpenAiBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'content': 'Checking both.',
                    'tool_calls': [
                      {
                        'id': 'call_1',
                        'function': {
                          'name': 'get_weather',
                          'arguments': '{"city":"Canberra"}',
                        },
                      },
                      {
                        'id': 'call_2',
                        'function': {
                          'name': 'get_time',
                          'arguments': '{"city":"Atlanta"}',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
      final done = await b.chatDetailed(
        apiKey: 'k',
        model: 'm',
        request: const ChatRequest(system: '', messages: []),
      );
      expect(done.text, 'Checking both.');
      expect(done.toolCalls.map((c) => c.id), ['call_1', 'call_2']);
      expect(done.toolCalls.last.arguments, {'city': 'Atlanta'});
    });

    test('feeds results back as one tool message per call', () async {
      late Map<String, Object?> sentBody;
      final b = OpenAiBroker(
        client: MockClient((req) async {
          sentBody = jsonDecode(req.body) as Map<String, Object?>;
          return Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'done'},
                },
              ],
            }),
            200,
          );
        }),
      );
      await b.chatDetailed(
        apiKey: 'k',
        model: 'm',
        request: const ChatRequest(
          system: '',
          messages: twoCallHistory,
          tools: [weatherTool, timeTool],
        ),
      );
      // Four messages, not three: OpenAI answers each call separately, the
      // opposite of Anthropic's single coalesced message.
      expect(sentBody['messages'], [
        {'role': 'user', 'content': 'weather and time?'},
        {
          'role': 'assistant',
          'content': 'Checking both.',
          'tool_calls': [
            {
              'id': 'toolu_01',
              'type': 'function',
              'function': {
                'name': 'get_weather',
                // Back to a string on the way out.
                'arguments': '{"city":"Canberra"}',
              },
            },
            {
              'id': 'toolu_02',
              'type': 'function',
              'function': {
                'name': 'get_time',
                'arguments': '{"city":"Atlanta"}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'toolu_01',
          'content': '18C and clear',
        },
        {'role': 'tool', 'tool_call_id': 'toolu_02', 'content': '9:04am'},
      ]);
    });

    test('sends null content on a tool-use turn with no text', () {
      final b = OpenAiBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      final payload = b.buildPayload(
        'm',
        const ChatRequest(
          system: '',
          messages: [
            AiMessage.assistantToolCalls([
              AiToolCall(id: 'call_1', name: 'get_weather', arguments: {}),
            ]),
          ],
        ),
        stream: false,
      );
      final assistant = (payload['messages']! as List<Object?>).single!
          as Map<String, Object?>;
      expect(assistant['content'], isNull);
      expect(assistant.containsKey('content'), isTrue);
    });

    test('assembles argument fragments while text keeps flowing', () async {
      final wire = StringBuffer()
        ..write(
          _data({
            'model': 'gpt-4o-2024-08-06',
            'choices': [
              {
                'delta': {'content': 'Checking '},
              },
            ],
          }),
        )
        ..write(
          _data({
            'choices': [
              {
                'delta': {'content': 'now.'},
              },
            ],
          }),
        )
        // Slot opens with the id and name and empty arguments…
        ..write(
          _data({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_abc',
                      'type': 'function',
                      'function': {'name': 'get_weather', 'arguments': ''},
                    },
                  ],
                },
              },
            ],
          }),
        )
        // …then the arguments dribble in, one unparseable fragment at a time.
        ..write(
          _data({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': '{"city":'},
                    },
                  ],
                },
              },
            ],
          }),
        )
        ..write(
          _data({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': '"Atlanta"}'},
                    },
                  ],
                },
              },
            ],
          }),
        )
        ..write(
          _data({
            'choices': [
              {'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
            ],
            'usage': {'prompt_tokens': 18, 'completion_tokens': 4},
          }),
        )
        ..write('data: [DONE]\n\n');
      final b = OpenAiBroker(
        client: MockClient.streaming(
          (_, __) async => StreamedResponse(
            Stream<List<int>>.value(utf8.encode(wire.toString())),
            200,
          ),
        ),
      );
      final turn = b.streamDetailed(
        apiKey: 'k',
        model: 'gpt-4o',
        request: const ChatRequest(
          system: '',
          messages: [],
          tools: [weatherTool],
        ),
      );
      expect(await turn.deltas.toList(), ['Checking ', 'now.']);
      final done = await turn.completion;
      expect(done.text, 'Checking now.');
      expect(done.stopReason, AiStopReason.toolUse);
      expect(done.toolCalls, hasLength(1));
      expect(done.toolCalls.single.id, 'call_abc');
      expect(done.toolCalls.single.name, 'get_weather');
      expect(done.toolCalls.single.arguments, {'city': 'Atlanta'});
      expect(done.model, 'gpt-4o-2024-08-06');
      expect(done.inputTokens, 18);
    });

    test('keys streamed fragments by index so two calls stay apart', () async {
      final wire = StringBuffer()
        ..write(
          _data({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_1',
                      'function': {'name': 'get_weather', 'arguments': '{"ci'},
                    },
                    {
                      'index': 1,
                      'id': 'call_2',
                      'function': {'name': 'get_time', 'arguments': '{"ci'},
                    },
                  ],
                },
              },
            ],
          }),
        )
        ..write(
          _data({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 1,
                      'function': {'arguments': 'ty":"Atlanta"}'},
                    },
                    {
                      'index': 0,
                      'function': {'arguments': 'ty":"Canberra"}'},
                    },
                  ],
                },
              },
            ],
          }),
        )
        ..write('data: [DONE]\n\n');
      final b = OpenAiBroker(
        client: MockClient.streaming(
          (_, __) async => StreamedResponse(
            Stream<List<int>>.value(utf8.encode(wire.toString())),
            200,
          ),
        ),
      );
      final turn = b.streamDetailed(
        apiKey: 'k',
        model: 'm',
        request: const ChatRequest(system: '', messages: []),
      );
      expect(await turn.deltas.toList(), isEmpty);
      final done = await turn.completion;
      expect(done.toolCalls.map((c) => c.name), ['get_weather', 'get_time']);
      expect(done.toolCalls.first.arguments, {'city': 'Canberra'});
      expect(done.toolCalls.last.arguments, {'city': 'Atlanta'});
    });

    test('chat() names the method that can return a tool call', () async {
      final b = OpenAiBroker(
        client: MockClient(
          (_) async => Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'content': null,
                    'tool_calls': [
                      {
                        'id': 'call_1',
                        'function': {'name': 'get_weather', 'arguments': '{}'},
                      },
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
          apiKey: 'k',
          model: 'm',
          request: const ChatRequest(system: '', messages: []),
        ),
        throwsA(
          isA<AiBrokerException>().having(
            (e) => e.message,
            'message',
            allOf(contains('chatDetailed'), contains('get_weather')),
          ),
        ),
      );
    });
  });
}

// -----------------------------------------------------------------------------
// Fixtures
// -----------------------------------------------------------------------------

/// Deliberately carries `additionalProperties` and a `description`: the first
/// is what Gemini rejects and must be translated away, the second is what the
/// translation has to keep.
const weatherSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'city': {'type': 'string', 'description': 'City name'},
  },
  'required': ['city'],
  'additionalProperties': false,
};

const weatherTool = AiTool(
  name: 'get_weather',
  description: 'Look up the current weather for a city.',
  inputSchema: weatherSchema,
);

const timeTool = AiTool(
  name: 'get_time',
  description: 'Look up the current local time for a city.',
  inputSchema: weatherSchema,
);

/// A finished round trip: the ask, the two calls, and both answers.
const twoCallHistory = <AiMessage>[
  AiMessage.user('weather and time?'),
  AiMessage.assistantToolCalls(
    [
      AiToolCall(
        id: 'toolu_01',
        name: 'get_weather',
        arguments: {'city': 'Canberra'},
      ),
      AiToolCall(
        id: 'toolu_02',
        name: 'get_time',
        arguments: {'city': 'Atlanta'},
      ),
    ],
    content: 'Checking both.',
  ),
  AiMessage.toolResult(toolCallId: 'toolu_01', content: '18C and clear'),
  AiMessage.toolResult(toolCallId: 'toolu_02', content: '9:04am'),
];

/// The same history with the ids Gemini would have synthesised.
const geminiTwoCallHistory = <AiMessage>[
  AiMessage.user('weather and time?'),
  AiMessage.assistantToolCalls(
    [
      AiToolCall(
        id: 'call_0_get_weather',
        name: 'get_weather',
        arguments: {'city': 'Canberra'},
      ),
      AiToolCall(
        id: 'call_1_get_time',
        name: 'get_time',
        arguments: {'city': 'Atlanta'},
      ),
    ],
    content: 'Checking both.',
  ),
  AiMessage.toolResult(
    toolCallId: 'call_0_get_weather',
    content: '18C and clear',
  ),
  AiMessage.toolResult(toolCallId: 'call_1_get_time', content: '9:04am'),
];

/// One framed SSE event with a name, as Anthropic writes it.
String _sse(String event, Map<String, Object?> data) =>
    'event: $event\ndata: ${jsonEncode(data)}\n\n';

/// One framed SSE event with no name, as OpenAI and Gemini write it.
String _data(Map<String, Object?> data) => 'data: ${jsonEncode(data)}\n\n';

void _thoughtSignatureTests() {
  group('Gemini thought signatures', () {
    // Gemini 3.x attaches a `thoughtSignature` to every functionCall part and
    // rejects the NEXT turn with a 400 if it is not echoed back verbatim:
    //   "Function call is missing a thought_signature in functionCall parts."
    // Verified against the live API — without it the continuation 400s, with it
    // the model answers. Nothing else in this package reads the value.
    test('a signature on the response part is captured onto the call', () {
      final calls = <AiToolCall>[];
      GeminiBroker.collectToolCalls(
        {
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'name': 'check_availability',
                      'args': {'date': '2026-09-10'},
                    },
                    'thoughtSignature': 'SIG-abc123',
                  },
                ],
              },
            },
          ],
        },
        calls,
      );
      expect(calls, hasLength(1));
      expect(calls.single.name, 'check_availability');
      expect(calls.single.providerSignature, 'SIG-abc123');
    });

    test('the signature is echoed back on the assistant turn', () {
      final broker = GeminiBroker();
      final payload = broker.buildPayload(
        const ChatRequest(
          system: '',
          messages: [
            AiMessage.user('free times?'),
            AiMessage.assistantToolCalls([
              AiToolCall(
                id: 'call_0',
                name: 'check_availability',
                arguments: {'date': '2026-09-10'},
                providerSignature: 'SIG-abc123',
              ),
            ]),
            AiMessage.toolResult(
              toolCallId: 'call_0',
              content: '{"slots":[]}',
            ),
          ],
        ),
      );
      final contents = payload['contents']! as List<Object?>;
      final modelTurn =
          contents.firstWhere((c) => (c! as Map)['role'] == 'model')!
              as Map<String, Object?>;
      final part = (modelTurn['parts']! as List).first as Map<String, Object?>;
      expect(part['thoughtSignature'], 'SIG-abc123');
      expect(part.containsKey('functionCall'), isTrue);
    });

    test('a call without a signature emits no empty key', () {
      final broker = GeminiBroker();
      final payload = broker.buildPayload(
        const ChatRequest(
          system: '',
          messages: [
            AiMessage.user('hi'),
            AiMessage.assistantToolCalls([
              AiToolCall(id: 'c0', name: 't', arguments: {}),
            ]),
            AiMessage.toolResult(toolCallId: 'c0', content: '{}'),
          ],
        ),
      );
      final contents = payload['contents']! as List<Object?>;
      final modelTurn =
          contents.firstWhere((c) => (c! as Map)['role'] == 'model')!
              as Map<String, Object?>;
      final part = (modelTurn['parts']! as List).first as Map<String, Object?>;
      expect(part.containsKey('thoughtSignature'), isFalse);
    });
  });
}
