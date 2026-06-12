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

import 'package:args/args.dart' show ArgParser, ArgResults;
import 'package:args/command_runner.dart';

import '/_common.dart';

/// Builds the `aib` / `ai_broker` CLI. Returns a configured
/// [CommandRunner] so tests (and `bin/ai_broker.dart`) can construct +
/// run it without duplicating wiring.
///
/// [brokerFactory] and [keyResolver] are dependency-injection seams used
/// by tests; production callers leave them null.
CommandRunner<int> buildAibRunner({
  AiBroker Function(String)? brokerFactory,
  KeyResolver? keyResolver,
}) {
  final runner = CommandRunner<int>(
    'ai_broker',
    'RAG toolkit on top of the ai_broker library: ingest text into a local '
        'vector store, search, chat, and build portable bundles for use with '
        'Claude Code.',
  );
  runner.addCommand(
    IngestCommand(brokerFactory: brokerFactory, keyResolver: keyResolver),
  );
  runner.addCommand(
    SearchCommand(brokerFactory: brokerFactory, keyResolver: keyResolver),
  );
  runner.addCommand(
    AskCommand(brokerFactory: brokerFactory, keyResolver: keyResolver),
  );
  runner.addCommand(
    TranslateCommand(brokerFactory: brokerFactory, keyResolver: keyResolver),
  );
  runner.addCommand(CollectionsCommand());
  return runner;
}

/// Resolves the [AiBroker] for [id]. Throws [UsageException] for unknown
/// ids so the CLI surfaces a clean error.
AiBroker brokerForId(String id) {
  switch (id) {
    case 'openai':
      return OpenAiBroker();
    case 'gemini':
      return GeminiBroker();
    case 'anthropic':
      return AnthropicBroker();
    case 'google_translate':
      return GoogleTranslateBroker();
    default:
      throw UsageException(
        'Unknown broker "$id". Use one of: openai, gemini, anthropic, '
            'google_translate.',
        '',
      );
  }
}

/// Default chat model id for an LLM-based translator wrapping the
/// given chat broker. Used by [TranslateCommand] when the user picks
/// `--broker openai|anthropic|gemini` without overriding `--model`.
String defaultChatModelFor(String brokerId) {
  switch (brokerId) {
    case 'openai':
      return 'gpt-4o-mini';
    case 'anthropic':
      return 'claude-sonnet-4-6';
    case 'gemini':
      return 'gemini-2.5-flash';
    default:
      throw ArgumentError('No default chat model for broker "$brokerId".');
  }
}

/// Default workbench DB path: `~/.ai_broker/corpus.db`. Honors `AIB_DB`
/// env var override. The directory is created lazily by callers as
/// needed.
String defaultWorkbenchDbPath() {
  final override = Platform.environment['AIB_DB'];
  if (override != null && override.isNotEmpty) return override;
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
  return '$home/.ai_broker/corpus.db';
}

/// Wires the standard key-source flags into [parser]. Every command
/// that needs an API key calls this from its constructor:
///
///   --openai-key      direct value
///   --anthropic-key   direct value
///   --gemini-key      direct value
///   --env-file        path to a .env file (overrides ./.env auto-detect)
///
/// Whether to also auto-detect `./.env` is governed at resolution time
/// (see [resolverFromArgs]).
void addKeyArgs(ArgParser parser) {
  parser
    ..addOption(
      'openai-key',
      help: 'OpenAI API key (highest priority — overrides env-file / env).',
    )
    ..addOption(
      'anthropic-key',
      help: 'Anthropic API key (highest priority).',
    )
    ..addOption(
      'gemini-key',
      help: 'Gemini API key (highest priority).',
    )
    ..addOption(
      'env-file',
      help: 'Path to a .env file with KEY=value lines. If omitted, the CLI '
          'looks for ./.env in the current working directory.',
    );
}

/// Builds a [KeyResolver] from CLI [args] using this precedence (first
/// non-empty hit wins):
///
///   1. `--openai-key` / `--anthropic-key` / `--gemini-key` (direct)
///   2. `--env-file <path>` if supplied; otherwise `./.env` if present
///   3. Process env vars (OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY)
///
/// Tests bypass this by passing a [KeyResolver] to the command
/// constructor directly.
KeyResolver resolverFromArgs(ArgResults args) {
  final layers = <KeyResolver>[];

  final direct = <String, String>{};
  for (final entry in {
    'openai': 'openai-key',
    'anthropic': 'anthropic-key',
    'gemini': 'gemini-key',
  }.entries) {
    final v = args[entry.value] as String?;
    if (v != null && v.isNotEmpty) direct[entry.key] = v;
  }
  if (direct.isNotEmpty) layers.add(MapKeyResolver(direct));

  final envFile = args['env-file'] as String?;
  if (envFile != null && envFile.isNotEmpty) {
    layers.add(FileKeyResolver.fromFile(envFile));
  } else if (File('.env').existsSync()) {
    layers.add(FileKeyResolver.fromFile('.env'));
  }

  layers.add(EnvKeyResolver());

  return layers.length == 1 ? layers.first : ChainedKeyResolver(layers);
}
