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

import 'dart:io';

import 'package:ai_broker/ai_broker.dart';
import 'package:test/test.dart';

/// Fake broker that handles both `embed` (for the query + the ingest)
/// and `chat`/`stream` (for the answer). Captures the [ChatRequest] so
/// tests can assert on the system prompt the CLI assembled.
class _AskFake implements ChatBroker, EmbedBroker {
  ChatRequest? lastChatRequest;
  bool streamCalled = false;
  bool chatCalled = false;

  @override
  String get id => 'openai'; // Doubles as the embed broker id.
  @override
  String get label => 'Fake';

  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  @override
  Future<String> complete({
    required String apiKey,
    required String model,
    required String system,
    required String user,
    double? temperature,
    int maxTokens = 2048,
  }) async =>
      '';

  @override
  Future<List<List<double>>> embed({
    required String apiKey,
    required String model,
    required List<String> inputs,
  }) async {
    // 4-d vector keyed on a marker word so ranking is deterministic.
    return [
      for (final s in inputs)
        [
          s.toLowerCase().contains('cat') ? 1.0 : 0.0,
          s.toLowerCase().contains('dog') ? 1.0 : 0.0,
          s.toLowerCase().contains('bird') ? 1.0 : 0.0,
          0.1, // small baseline so all-zero vectors don't break cosine.
        ],
    ];
  }

  @override
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    chatCalled = true;
    lastChatRequest = request;
    return 'cats love to nap.';
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async* {
    streamCalled = true;
    lastChatRequest = request;
    yield 'cats ';
    yield 'love ';
    yield 'to nap.';
  }

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
}

void main() {
  group('AskCommand end-to-end', () {
    late Directory tmp;
    late String dbPath;
    late _AskFake fake;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('aib_ask_test_');
      dbPath = '${tmp.path}/corpus.db';
      fake = _AskFake();

      File('${tmp.path}/animals.md').writeAsStringSync(
        // Three sentences, one per marker word. Default chunker keeps
        // them as separate chunks so retrieval can discriminate.
        'A cat is a small furry feline. '
        'A dog is a loyal canine. '
        'A bird is a flying creature.',
      );

      final runner = buildAibRunner(
        brokerFactory: (_) => fake,
        keyResolver: MapKeyResolver({'openai': 'sk-test'}),
      );
      final code = await runner.run([
        'ingest',
        '--collection',
        'animals',
        '--db',
        dbPath,
        '--chunk-size',
        '8', // very small target so each sentence gets its own chunk.
        '--chunk-overlap',
        '0',
        '${tmp.path}/animals.md',
      ]);
      expect(code, 0, reason: 'ingest failed during setUp');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('streams the answer and feeds top-K snippets as system context',
        () async {
      // Fresh fake so the ingest's chat/stream flags don't leak.
      final freshFake = _AskFake();
      final runner = buildAibRunner(
        brokerFactory: (_) => freshFake,
        keyResolver: MapKeyResolver({
          'openai': 'sk-test',
          'anthropic': 'sk-ant-test',
        }),
      );
      final code = await runner.run([
        'ask',
        '--collection',
        'animals',
        '--db',
        dbPath,
        '--top-k',
        '2',
        '--no-citations',
        'tell me about cats',
      ]);
      expect(code, 0);

      // Streaming is the default — chat() should NOT have been called.
      expect(freshFake.streamCalled, isTrue);
      expect(freshFake.chatCalled, isFalse);

      // The system prompt should carry numbered excerpts and the
      // grounding instructions; the user message is just the question.
      final req = freshFake.lastChatRequest!;
      expect(req.system, contains('[^1]'));
      expect(req.system, contains('animals.md#'));
      expect(req.system.toLowerCase(), contains('cat'));
      expect(req.messages, hasLength(1));
      expect(req.messages.single.content, 'tell me about cats');
    });

    test('--no-stream uses the batched chat() instead of stream()', () async {
      final freshFake = _AskFake();
      final runner = buildAibRunner(
        brokerFactory: (_) => freshFake,
        keyResolver: MapKeyResolver({
          'openai': 'sk-test',
          'anthropic': 'sk-ant-test',
        }),
      );
      final code = await runner.run([
        'ask',
        '--collection',
        'animals',
        '--db',
        dbPath,
        '--no-stream',
        '--no-citations',
        'cats',
      ]);
      expect(code, 0);
      expect(freshFake.chatCalled, isTrue);
      expect(freshFake.streamCalled, isFalse);
    });

    test('missing collection returns exit 1', () async {
      final runner = buildAibRunner(
        brokerFactory: (_) => _AskFake(),
        keyResolver: MapKeyResolver({
          'openai': 'sk-test',
          'anthropic': 'sk-ant-test',
        }),
      );
      final code = await runner.run([
        'ask',
        '--collection',
        'does-not-exist',
        '--db',
        dbPath,
        'anything',
      ]);
      expect(code, 1);
    });

    test('missing db returns exit 1', () async {
      final runner = buildAibRunner(
        brokerFactory: (_) => _AskFake(),
        keyResolver: MapKeyResolver({
          'openai': 'sk-test',
          'anthropic': 'sk-ant-test',
        }),
      );
      final code = await runner.run([
        'ask',
        '--db',
        '${tmp.path}/missing.db',
        'q',
      ]);
      expect(code, 1);
    });

    test('rejects calls without a question argument', () async {
      final runner = buildAibRunner(
        brokerFactory: (_) => _AskFake(),
        keyResolver: MapKeyResolver({
          'openai': 'sk-test',
          'anthropic': 'sk-ant-test',
        }),
      );
      final code = await runner.run([
        'ask',
        '--collection',
        'animals',
        '--db',
        dbPath,
      ]);
      expect(code, 64); // EX_USAGE
    });
  });
}
