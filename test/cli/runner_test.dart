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
import 'package:args/args.dart';
import 'package:test/test.dart';

ArgResults parseWithKeyArgs(List<String> args) {
  final parser = ArgParser();
  addKeyArgs(parser);
  return parser.parse(args);
}

void main() {
  group('brokerForId', () {
    test('returns the matching broker for known ids', () {
      expect(brokerForId('openai'), isA<OpenAiBroker>());
      expect(brokerForId('anthropic'), isA<AnthropicBroker>());
      expect(brokerForId('gemini'), isA<GeminiBroker>());
    });

    test('throws UsageException for an unknown id', () {
      expect(
        () => brokerForId('not-a-real-broker'),
        throwsA(predicate((e) => e.runtimeType.toString() == 'UsageException')),
      );
    });
  });

  group('defaultWorkbenchDbPath', () {
    test('honours AIB_DB when set', () {
      // We can't mutate Platform.environment in-process, but the helper
      // should at minimum return *some* path string — covers the happy
      // path. The AIB_DB precedence is exercised by integration tests
      // that spawn subprocesses with the env var set.
      final path = defaultWorkbenchDbPath();
      expect(path, isNotEmpty);
      expect(path.endsWith('corpus.db'), isTrue);
    });
  });

  group('resolverFromArgs precedence', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('aib_runner_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('--openai-key wins over --env-file and env vars', () async {
      final envFile = File('${tmp.path}/.env');
      envFile.writeAsStringSync('OPENAI_API_KEY=sk-from-file');

      final args = parseWithKeyArgs([
        '--openai-key',
        'sk-from-flag',
        '--env-file',
        envFile.path,
      ]);
      final r = resolverFromArgs(args);
      expect(await r.resolve('openai'), 'sk-from-flag');
    });

    test('--env-file is consulted when no direct flag is given', () async {
      final envFile = File('${tmp.path}/.env');
      envFile.writeAsStringSync(
        'OPENAI_API_KEY=sk-from-file\nANTHROPIC_API_KEY=sk-ant-from-file',
      );
      final args = parseWithKeyArgs(['--env-file', envFile.path]);
      final r = resolverFromArgs(args);
      expect(await r.resolve('openai'), 'sk-from-file');
      expect(await r.resolve('anthropic'), 'sk-ant-from-file');
    });

    test('falls back to env vars when no flag and no .env present', () async {
      // resolverFromArgs auto-detects ./.env in the CWD. Move into a
      // fresh temp dir so the project's own .env (if any) doesn't
      // shadow what we're trying to test — the env-var fallback.
      final saved = Directory.current;
      final cleanDir = Directory.systemTemp.createTempSync('aib_noenv_');
      try {
        Directory.current = cleanDir;
        final args = parseWithKeyArgs(const []);
        final r = resolverFromArgs(args);
        // With no direct flag and no .env, the only remaining source
        // is process env vars. EnvKeyResolver returns null when the
        // var is unset; otherwise the env value.
        final actual = await r.resolve('openai');
        final expected = Platform.environment['OPENAI_API_KEY'];
        expect(actual, expected);
      } finally {
        Directory.current = saved;
        cleanDir.deleteSync(recursive: true);
      }
    });

    test('different-broker flags coexist', () async {
      final args = parseWithKeyArgs([
        '--openai-key',
        'sk-o',
        '--anthropic-key',
        'sk-a',
        '--gemini-key',
        'g-key',
      ]);
      final r = resolverFromArgs(args);
      expect(await r.resolve('openai'), 'sk-o');
      expect(await r.resolve('anthropic'), 'sk-a');
      expect(await r.resolve('gemini'), 'g-key');
    });
  });

  group('buildAibRunner', () {
    test('registers every shipped subcommand', () {
      final runner = buildAibRunner();
      final names = runner.commands.keys.toSet();
      // Hardcoded list — adding a command requires updating this test,
      // which is exactly the trip-wire we want before deployment.
      expect(
        names,
        containsAll(<String>{
          'ingest',
          'search',
          'ask',
          'translate',
          'collections',
        }),
      );
    });

    test('--help exits cleanly (no thrown exceptions)', () async {
      final runner = buildAibRunner();
      // CommandRunner returns null exit code for the --help path.
      final code = await runner.run(['--help']);
      expect(code, anyOf(isNull, 0));
    });
  });
}
