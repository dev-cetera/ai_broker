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

/// Implements only the primitives ([chatWithMeta] + [stream]), so
/// [ChatBroker.chat], [ChatBroker.complete] and
/// [ChatBroker.completeWithMeta] come from the defaults on [ChatBroker].
/// Captures the [ChatRequest] each call sends.
class _CapturingChat extends ChatBroker {
  ChatRequest? captured;

  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  @override
  Future<AiCompletion> chatWithMeta({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    captured = request;
    return const AiCompletion(
      text: '<<captured>>',
      rawFinishReason: 'max_tokens',
      finishReason: AiFinishReason.maxTokens,
      inputTokens: 1,
      outputTokens: 2,
    );
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) =>
      const Stream<String>.empty();

  @override
  StreamedCompletion streamWithMeta({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) =>
      StreamedCompletion.fromDeltas(
        deltas: stream(apiKey: apiKey, model: model, request: request),
        model: model,
      );
}

/// A broker that overrides nothing but the two abstract methods — exactly
/// the case the default [ChatBroker.streamWithMeta] exists for.
class _PlainChat extends ChatBroker {
  /// Makes [stream] fail instead of yielding, to exercise the error path.
  bool fail = false;

  @override
  String get id => 'plain';
  @override
  String get label => 'Plain';
  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  @override
  Future<AiCompletion> chatWithMeta({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async =>
      const AiCompletion(text: 'hello world');

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async* {
    if (fail) throw const AiBrokerException('provider down');
    yield 'hello ';
    yield 'world';
  }
}

void main() {
  group('ChatBroker.streamWithMeta default impl', () {
    const request = ChatRequest(system: '', messages: []);

    test('yields the same deltas as stream() and settles a completion',
        () async {
      final b = _PlainChat();
      final turn = b.streamWithMeta(apiKey: 'k', model: 'm', request: request);
      expect(await turn.deltas.toList(), ['hello ', 'world']);
      final done = await turn.completion;
      expect(done.text, 'hello world');
      expect(done.model, 'm');
      // Best effort: a bare delta stream carries no accounting at all.
      expect(done.finishReason, AiFinishReason.stop);
      expect(done.inputTokens, isNull);
      expect(done.outputTokens, isNull);
      expect(done.cacheReadInputTokens, 0);
      expect(done.cacheCreationInputTokens, 0);
    });

    test('a failing stream fails the completion too', () async {
      final b = _PlainChat()..fail = true;
      final turn = b.streamWithMeta(apiKey: 'k', model: 'm', request: request);
      await expectLater(
        turn.deltas.toList(),
        throwsA(isA<AiBrokerException>()),
      );
      await expectLater(turn.completion, throwsA(isA<AiBrokerException>()));
    });
  });

  group('ChatBroker.complete default impl', () {
    test('delegates to chatWithMeta() with a single-user-message ChatRequest',
        () async {
      final b = _CapturingChat();
      final out = await b.complete(
        apiKey: 'k',
        model: 'm',
        system: 'system prompt',
        user: 'hello',
      );
      expect(out, '<<captured>>');
      expect(b.captured, isNotNull);
      expect(b.captured!.system, 'system prompt');
      expect(b.captured!.messages, hasLength(1));
      expect(b.captured!.messages.single.content, 'hello');
      expect(b.captured!.messages.single.role, AiRole.user);
    });

    test('forwards temperature and maxTokens', () async {
      final b = _CapturingChat();
      await b.complete(
        apiKey: 'k',
        model: 'm',
        system: '',
        user: 'q',
        temperature: 0.7,
        maxTokens: 512,
      );
      expect(b.captured!.temperature, 0.7);
      expect(b.captured!.maxTokens, 512);
    });
  });

  group('ChatBroker *WithMeta defaults', () {
    test('completeWithMeta sends one user message through chatWithMeta',
        () async {
      final b = _CapturingChat();
      final out = await b.completeWithMeta(
        apiKey: 'k',
        model: 'm',
        system: 'sys',
        user: 'hi',
        temperature: 0.5,
        maxTokens: 64,
      );
      expect(out.text, '<<captured>>');
      expect(out.finishReason, AiFinishReason.maxTokens);
      final sent = b.captured!;
      expect(sent.system, 'sys');
      expect(sent.messages.single.content, 'hi');
      expect(sent.temperature, 0.5);
      expect(sent.maxTokens, 64);
    });

    test('complete and chat return the text of the meta call', () async {
      final b = _CapturingChat();
      expect(
        await b.complete(apiKey: 'k', model: 'm', system: 's', user: 'u'),
        '<<captured>>',
      );
      expect(
        await b.chat(
          apiKey: 'k',
          model: 'm',
          request: ChatRequest.single(system: 's', user: 'u'),
        ),
        '<<captured>>',
      );
    });
  });
}
