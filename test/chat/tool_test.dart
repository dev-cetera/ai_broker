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

import 'package:ai_broker/ai_broker.dart';
import 'package:test/test.dart';

void main() {
  group('AiTool', () {
    test('carries the name, description and schema it was given', () {
      const tool = AiTool(
        name: 'get_weather',
        description: 'Look up the weather.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
          },
        },
      );
      expect(tool.name, 'get_weather');
      expect(tool.description, 'Look up the weather.');
      expect(tool.inputSchema['type'], 'object');
      expect(tool.toString(), contains('get_weather'));
    });
  });

  group('AiToolChoice', () {
    test('has a wire string per mode', () {
      expect(AiToolChoice.auto.wire, 'auto');
      expect(AiToolChoice.none.wire, 'none');
      expect(AiToolChoice.required.wire, 'required');
    });
  });

  group('AiToolCall', () {
    test('holds an id, a name and decoded arguments', () {
      const call = AiToolCall(
        id: 'toolu_1',
        name: 'get_weather',
        arguments: {'city': 'Canberra'},
      );
      expect(call.id, 'toolu_1');
      expect(call.name, 'get_weather');
      expect(call.arguments['city'], 'Canberra');
    });
  });

  group('decodeToolArguments', () {
    test('passes a JSON object straight through', () {
      expect(
        decodeToolArguments(<String, Object?>{'city': 'Atlanta', 'days': 3}),
        {'city': 'Atlanta', 'days': 3},
      );
    });

    test('parses the JSON string OpenAI sends', () {
      expect(
        decodeToolArguments('{"city":"Gold Coast","days":3}'),
        {'city': 'Gold Coast', 'days': 3},
      );
    });

    test('parses a string whose value contains JSON-looking text', () {
      // The reason this is a parse and not a string match: a value can hold
      // braces and escaped quotes, and any regex over the raw text gets them
      // wrong.
      final args = decodeToolArguments(r'{"query":"{\"not\":\"json\"}"}');
      expect(args, {'query': '{"not":"json"}'});
    });

    test('returns an empty map for null, empty and malformed input', () {
      expect(decodeToolArguments(null), isEmpty);
      expect(decodeToolArguments(''), isEmpty);
      expect(decodeToolArguments('   '), isEmpty);
      // A stream cut mid-object — surface the call, not a half-parsed map.
      expect(decodeToolArguments('{"city":"Can'), isEmpty);
      expect(decodeToolArguments('[1,2,3]'), isEmpty);
      expect(decodeToolArguments(42), isEmpty);
    });

    test('normalises a dynamic map from jsonDecode to one key type', () {
      final dynamic raw = <dynamic, dynamic>{'city': 'Brisbane'};
      expect(decodeToolArguments(raw), {'city': 'Brisbane'});
    });

    test('copies rather than aliasing the input', () {
      final source = <String, Object?>{'city': 'Canberra'};
      final decoded = decodeToolArguments(source)..['city'] = 'Atlanta';
      expect(source['city'], 'Canberra');
      expect(decoded['city'], 'Atlanta');
    });
  });

  group('AiMessage', () {
    test('ordinary messages carry no tool data', () {
      const user = AiMessage.user('hi');
      expect(user.toolCalls, isEmpty);
      expect(user.toolCallId, isNull);
      expect(user.isToolResult, isFalse);
      expect(user.isError, isFalse);
      expect(user.toString(), 'user: hi');
    });

    test('assistantToolCalls records the calls and defaults to no text', () {
      const message = AiMessage.assistantToolCalls([
        AiToolCall(id: 'toolu_1', name: 'get_weather', arguments: {}),
      ]);
      expect(message.role, AiRole.assistant);
      expect(message.content, '');
      expect(message.toolCalls.single.name, 'get_weather');
      expect(message.isToolResult, isFalse);
      expect(message.toString(), contains('get_weather'));
    });

    test('toolResult is a user message tied to a call id', () {
      const result = AiMessage.toolResult(
        toolCallId: 'toolu_1',
        content: '18C and clear',
      );
      expect(result.role, AiRole.user);
      expect(result.roleName, 'user');
      expect(result.toolCallId, 'toolu_1');
      expect(result.content, '18C and clear');
      expect(result.isError, isFalse);
      expect(result.isToolResult, isTrue);
    });

    test('toolResult can report a failure', () {
      const result = AiMessage.toolResult(
        toolCallId: 'toolu_1',
        content: 'upstream timed out',
        isError: true,
      );
      expect(result.isError, isTrue);
      expect(result.isToolResult, isTrue);
    });
  });

  group('ChatRequest', () {
    test('tools and toolChoice default to null', () {
      const request = ChatRequest(system: '', messages: []);
      expect(request.tools, isNull);
      expect(request.toolChoice, isNull);
    });

    test('carries tools and a choice when given', () {
      const request = ChatRequest(
        system: 'be useful',
        messages: [AiMessage.user('weather?')],
        tools: [
          AiTool(name: 'get_weather', description: 'd', inputSchema: {}),
        ],
        toolChoice: AiToolChoice.required,
      );
      expect(request.tools!.single.name, 'get_weather');
      expect(request.toolChoice, AiToolChoice.required);
    });

    test('single() forwards tools and toolChoice', () {
      final request = ChatRequest.single(
        system: 's',
        user: 'u',
        tools: const [
          AiTool(name: 'get_time', description: 'd', inputSchema: {}),
        ],
        toolChoice: AiToolChoice.none,
      );
      expect(request.tools!.single.name, 'get_time');
      expect(request.toolChoice, AiToolChoice.none);
    });
  });

  group('AiCompletion', () {
    test('toolCalls defaults to empty and wantsTool is false', () {
      const done = AiCompletion(
        text: 'hi',
        model: 'm',
        stopReason: AiStopReason.endTurn,
      );
      expect(done.toolCalls, isEmpty);
      expect(done.wantsTool, isFalse);
      expect(done.toString(), isNot(contains('tools')));
    });

    test('wantsTool follows the stop reason', () {
      const done = AiCompletion(
        text: '',
        model: 'm',
        stopReason: AiStopReason.toolUse,
        toolCalls: [
          AiToolCall(id: 'toolu_1', name: 'get_weather', arguments: {}),
        ],
      );
      expect(done.wantsTool, isTrue);
      expect(done.isRefusal, isFalse);
      expect(done.toString(), contains('tools: 1'));
    });
  });
}
