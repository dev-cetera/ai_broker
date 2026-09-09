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

/// Captures the [ChatRequest] passed to [chat] so we can assert the
/// default [ChatBroker.complete] delegates correctly.
class _CapturingChat implements ChatBroker {
  ChatRequest? captured;

  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  // Re-declare `complete` exactly as on the interface so the default
  // delegation lands here. Dart's `implements` doesn't inherit default
  // method bodies, so without this the class would be abstract.
  @override
  Future<String> complete({
    required String apiKey,
    required String model,
    required String system,
    required String user,
    double? temperature,
    int maxTokens = 2048,
  }) =>
      chat(
        apiKey: apiKey,
        model: model,
        request: ChatRequest.single(
          system: system,
          user: user,
          temperature: temperature,
          maxTokens: maxTokens,
        ),
      );

  @override
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    captured = request;
    return '<<captured>>';
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) =>
      const Stream<String>.empty();

  @override
  Future<AiCompletion> chatDetailed({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async =>
      AiCompletion(
        text: await chat(apiKey: apiKey, model: model, request: request),
        model: model,
        stopReason: AiStopReason.endTurn,
      );

  @override
  StreamedCompletion streamDetailed({
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
/// the case the default [ChatBroker.streamDetailed] exists for.
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
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async =>
      'hello world';

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
  group('ChatBroker.streamDetailed default impl', () {
    const request = ChatRequest(system: '', messages: []);

    test('yields the same deltas as stream() and settles a completion',
        () async {
      final b = _PlainChat();
      final turn = b.streamDetailed(apiKey: 'k', model: 'm', request: request);
      expect(await turn.deltas.toList(), ['hello ', 'world']);
      final done = await turn.completion;
      expect(done.text, 'hello world');
      expect(done.model, 'm');
      // Best effort: a bare delta stream carries no accounting at all.
      expect(done.stopReason, AiStopReason.endTurn);
      expect(done.inputTokens, 0);
      expect(done.outputTokens, 0);
      expect(done.cacheReadInputTokens, 0);
      expect(done.cacheCreationInputTokens, 0);
    });

    test('a failing stream fails the completion too', () async {
      final b = _PlainChat()..fail = true;
      final turn = b.streamDetailed(apiKey: 'k', model: 'm', request: request);
      await expectLater(
        turn.deltas.toList(),
        throwsA(isA<AiBrokerException>()),
      );
      await expectLater(turn.completion, throwsA(isA<AiBrokerException>()));
    });
  });

  group('ChatBroker.complete default impl', () {
    test('delegates to chat() with a single-user-message ChatRequest',
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
}
