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

import 'package:ai_broker/ai_broker.dart';
import 'package:test/test.dart';

void main() {
  group('AiMessage', () {
    test('AiMessage.user sets role to user', () {
      const m = AiMessage.user('hi');
      expect(m.role, AiRole.user);
      expect(m.content, 'hi');
    });

    test('AiMessage.assistant sets role to assistant', () {
      const m = AiMessage.assistant('there');
      expect(m.role, AiRole.assistant);
      expect(m.content, 'there');
    });

    test('positional constructor accepts an arbitrary role', () {
      const m = AiMessage(AiRole.assistant, 'echo');
      expect(m.role, AiRole.assistant);
      expect(m.content, 'echo');
    });

    test('roleName maps user to "user"', () {
      expect(const AiMessage.user('x').roleName, 'user');
    });

    test('roleName maps assistant to "assistant"', () {
      expect(const AiMessage.assistant('x').roleName, 'assistant');
    });

    test('toString includes role and content', () {
      expect(const AiMessage.user('hi').toString(), 'user: hi');
      expect(const AiMessage.assistant('ok').toString(), 'assistant: ok');
    });
  });

  group('ChatRequest', () {
    test('omits temperature by default and defaults maxTokens to 2048', () {
      const req = ChatRequest(system: 's', messages: []);
      expect(req.temperature, isNull);
      expect(req.maxTokens, 2048);
    });

    test('keeps the message list as provided', () {
      const req = ChatRequest(
        system: 's',
        messages: [
          AiMessage.user('a'),
          AiMessage.assistant('b'),
          AiMessage.user('c'),
        ],
      );
      expect(req.messages, hasLength(3));
      expect(req.messages.first.role, AiRole.user);
      expect(req.messages[1].role, AiRole.assistant);
      expect(req.messages.last.content, 'c');
    });

    test('ChatRequest.single wraps the user message into a single-entry list',
        () {
      final req = ChatRequest.single(system: 'sys', user: 'hello');
      expect(req.system, 'sys');
      expect(req.messages, hasLength(1));
      expect(req.messages.single.role, AiRole.user);
      expect(req.messages.single.content, 'hello');
    });

    test('ChatRequest.single forwards temperature and maxTokens', () {
      final req = ChatRequest.single(
        system: 's',
        user: 'u',
        temperature: 0.9,
        maxTokens: 64,
      );
      expect(req.temperature, 0.9);
      expect(req.maxTokens, 64);
    });
  });
}
