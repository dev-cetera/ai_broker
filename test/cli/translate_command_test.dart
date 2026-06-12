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

/// Native fake for the `google_translate` path. Records the args it
/// received so we can assert the CLI forwarded them correctly.
class _FakeTranslate implements TranslateBroker {
  String? lastText;
  String? lastTo;
  String? lastFrom;
  String? lastDomain;
  String? lastTone;
  String? lastContext;
  Map<String, String>? lastGlossary;
  String resultText = 'translated!';

  @override
  String get id => 'google_translate';
  @override
  String get label => 'Fake GT';
  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  @override
  Future<TranslationResult> translate({
    required String apiKey,
    required String text,
    required String to,
    String? from,
    String? model,
    String? domain,
    String? tone,
    Map<String, String>? glossary,
    String? context,
  }) async {
    lastText = text;
    lastTo = to;
    lastFrom = from;
    lastDomain = domain;
    lastTone = tone;
    lastContext = context;
    lastGlossary = glossary;
    return TranslationResult(
      translated: resultText,
      detectedFrom: from == null ? 'en' : null,
    );
  }
}

/// Fake chat broker for the `--broker openai` (LLM-translator) path.
class _FakeChat implements ChatBroker {
  ChatRequest? captured;
  String? capturedModel;

  @override
  String get id => 'openai';
  @override
  String get label => 'Fake Chat';
  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  @override
  Future<String> complete({
    required String apiKey,
    required String model,
    required String system,
    required String user,
    double temperature = 0.3,
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
    capturedModel = model;
    captured = request;
    return 'llm translation';
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) =>
      const Stream<String>.empty();
}

void main() {
  group('TranslateCommand', () {
    test('routes through TranslateBroker (google_translate path)', () async {
      final fake = _FakeTranslate();
      final runner = buildAibRunner(
        brokerFactory: (_) => fake,
        keyResolver: MapKeyResolver({'google_translate': 'AIza-test'}),
      );
      final code = await runner.run([
        'translate',
        '--to',
        'fr',
        '--from',
        'en',
        'hello world',
      ]);
      expect(code, 0);
      expect(fake.lastText, 'hello world');
      expect(fake.lastTo, 'fr');
      expect(fake.lastFrom, 'en');
    });

    test('parses --glossary inline pairs', () async {
      final fake = _FakeTranslate();
      final runner = buildAibRunner(
        brokerFactory: (_) => fake,
        keyResolver: MapKeyResolver({'google_translate': 'k'}),
      );
      final code = await runner.run([
        'translate',
        '--to',
        'fr',
        '--glossary',
        'BME280=BME280,catalyst=catalyseur',
        'text',
      ]);
      expect(code, 0);
      expect(fake.lastGlossary, {
        'BME280': 'BME280',
        'catalyst': 'catalyseur',
      });
    });

    test('parses --glossary-file (one source=target per line, # comments)',
        () async {
      final tmp = Directory.systemTemp.createTempSync('aib_glossary_');
      try {
        File('${tmp.path}/g.txt').writeAsStringSync(
          '# my glossary\n'
          'BME280=BME280\n'
          '\n'
          'catalyst=catalyseur\n',
        );
        final fake = _FakeTranslate();
        final runner = buildAibRunner(
          brokerFactory: (_) => fake,
          keyResolver: MapKeyResolver({'google_translate': 'k'}),
        );
        final code = await runner.run([
          'translate',
          '--to',
          'fr',
          '--glossary-file',
          '${tmp.path}/g.txt',
          'text',
        ]);
        expect(code, 0);
        expect(fake.lastGlossary, {
          'BME280': 'BME280',
          'catalyst': 'catalyseur',
        });
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('--glossary inline overrides file entries with the same source',
        () async {
      final tmp = Directory.systemTemp.createTempSync('aib_glossary_');
      try {
        File(
          '${tmp.path}/g.txt',
        ).writeAsStringSync('foo=from_file\nbar=from_file');
        final fake = _FakeTranslate();
        final runner = buildAibRunner(
          brokerFactory: (_) => fake,
          keyResolver: MapKeyResolver({'google_translate': 'k'}),
        );
        await runner.run([
          'translate',
          '--to',
          'fr',
          '--glossary-file',
          '${tmp.path}/g.txt',
          '--glossary',
          'foo=from_inline,baz=new',
          'text',
        ]);
        expect(fake.lastGlossary, {
          'foo': 'from_inline', // overridden by inline
          'bar': 'from_file', // file-only
          'baz': 'new', // inline-only
        });
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('wraps a chat-only broker in LlmTranslator and forwards hints',
        () async {
      final chat = _FakeChat();
      final runner = buildAibRunner(
        brokerFactory: (_) => chat,
        keyResolver: MapKeyResolver({'openai': 'sk-test'}),
      );
      final code = await runner.run([
        'translate',
        '--to',
        'fr',
        '--broker',
        'openai',
        '--domain',
        'medical',
        '--tone',
        'formal',
        '--context',
        'this is a research abstract',
        'mucosa',
      ]);
      expect(code, 0);
      expect(chat.captured, isNotNull);
      final sys = chat.captured!.system;
      expect(sys.toLowerCase(), contains('medical'));
      expect(sys.toLowerCase(), contains('formal'));
      expect(sys, contains('research abstract'));
      expect(chat.captured!.messages.single.content, 'mucosa');
    });

    test('--model overrides the default chat model for LLM brokers', () async {
      final chat = _FakeChat();
      final runner = buildAibRunner(
        brokerFactory: (_) => chat,
        keyResolver: MapKeyResolver({'openai': 'sk-test'}),
      );
      await runner.run([
        'translate',
        '--to',
        'fr',
        '--broker',
        'openai',
        '--model',
        'gpt-4o',
        'q',
      ]);
      expect(chat.capturedModel, 'gpt-4o');
    });

    test('--to is required', () async {
      final runner = buildAibRunner(
        brokerFactory: (_) => _FakeTranslate(),
        keyResolver: MapKeyResolver({'google_translate': 'k'}),
      );
      final code = await runner.run(['translate', 'hello']);
      expect(code, 64);
    });

    test('rejects malformed inline glossary entries', () async {
      final fake = _FakeTranslate();
      final runner = buildAibRunner(
        brokerFactory: (_) => fake,
        keyResolver: MapKeyResolver({'google_translate': 'k'}),
      );
      final code = await runner.run([
        'translate',
        '--to',
        'fr',
        '--glossary',
        'not_a_pair',
        'text',
      ]);
      expect(code, 64);
    });

    test('exit 64 when the text argument is missing', () async {
      final runner = buildAibRunner(
        brokerFactory: (_) => _FakeTranslate(),
        keyResolver: MapKeyResolver({'google_translate': 'k'}),
      );
      final code = await runner.run(['translate', '--to', 'fr']);
      expect(code, 64);
    });
  });
}
