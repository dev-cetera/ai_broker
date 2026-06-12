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

import 'package:args/command_runner.dart';

import '/_common.dart';

/// `ai_broker translate <text>` — translate via Google Cloud
/// Translation (default) or via any [ChatBroker] (`--broker openai` /
/// `anthropic` / `gemini`), with optional context hints and a
/// client-side glossary.
class TranslateCommand extends Command<int> {
  final AiBroker Function(String) _brokerFactory;
  final KeyResolver? _keyResolverOverride;

  TranslateCommand({
    AiBroker Function(String)? brokerFactory,
    KeyResolver? keyResolver,
  })  : _brokerFactory = brokerFactory ?? brokerForId,
        _keyResolverOverride = keyResolver {
    addKeyArgs(argParser);
    argParser
      ..addOption(
        'to',
        help: 'Target language code (e.g. fr, es, de, ja). Required.',
      )
      ..addOption(
        'from',
        help: 'Source language code. Omit to auto-detect.',
      )
      ..addOption(
        'broker',
        defaultsTo: 'google_translate',
        allowed: [
          'google_translate',
          'openai',
          'anthropic',
          'gemini',
        ],
        help: 'Translator backend. "google_translate" uses Google Cloud '
            'Translation v2; the chat brokers route through an LLM '
            'translator (richer context-handling, higher cost).',
      )
      ..addOption(
        'model',
        help: 'Model override for LLM brokers (ignored by google_translate).',
      )
      ..addOption(
        'domain',
        help: 'Optional domain hint (e.g. "medical", "legal"). '
            'Honoured by LLM brokers; ignored by google_translate.',
      )
      ..addOption(
        'tone',
        help: 'Optional tone hint (e.g. "formal", "casual"). Affects '
            'pronouns / verb forms. LLM brokers only.',
      )
      ..addOption(
        'glossary',
        help: 'Comma-separated source=target pairs. Example: '
            '"BME280=BME280,catalyst=catalyseur". Use --glossary-file '
            'for larger lists.',
      )
      ..addOption(
        'glossary-file',
        help: 'Path to a glossary file with one "source=target" per line.',
      )
      ..addOption(
        'context',
        help: 'Free-form context (surrounding text, stylistic notes). '
            'LLM brokers only.',
      )
      ..addFlag(
        'detected',
        defaultsTo: true,
        help: 'When source language was auto-detected, append a line '
            'noting what was detected (only when --from is omitted).',
      );
  }

  @override
  String get name => 'translate';

  @override
  String get description =>
      'Translate text via Google Cloud Translation or an LLM broker. '
      'Supports glossary, domain, tone, and free-form context hints.';

  @override
  String get invocation => '${runner!.executableName} $name <text>';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length != 1) {
      stderr.writeln(
        'translate: expected exactly one text argument.\n\n$usage',
      );
      return 64;
    }
    final text = args.rest.single;
    final to = args['to'] as String?;
    if (to == null || to.isEmpty) {
      stderr.writeln('translate: --to <lang> is required.');
      return 64;
    }
    final from = args['from'] as String?;
    final brokerId = args['broker'] as String;
    final model = args['model'] as String?;
    final domain = args['domain'] as String?;
    final tone = args['tone'] as String?;
    final context = args['context'] as String?;
    final showDetected = args['detected'] as bool;

    final glossary = _parseGlossary(
      inline: args['glossary'] as String?,
      filePath: args['glossary-file'] as String?,
    );
    if (glossary == null) return 64; // _parseGlossary already wrote stderr.

    final resolver = _keyResolverOverride ?? resolverFromArgs(args);
    final broker = _brokerFactory(brokerId);

    // Resolve to a TranslateBroker: native if the broker implements it,
    // otherwise wrap a ChatBroker with LlmTranslator.
    final TranslateBroker translator;
    if (broker is TranslateBroker) {
      translator = broker;
    } else if (broker is ChatBroker) {
      translator = LlmTranslator(
        chatBroker: broker,
        defaultModel: model ?? defaultChatModelFor(brokerId),
      );
    } else {
      stderr.writeln(
        'translate: broker "$brokerId" does not support translation or chat.',
      );
      return 1;
    }

    final apiKey = await resolver.require(broker.id);

    final result = await translator.translate(
      apiKey: apiKey,
      text: text,
      to: to,
      from: from,
      model: model,
      domain: domain,
      tone: tone,
      glossary: glossary.isEmpty ? null : glossary,
      context: context,
    );

    stdout.write(result.translated);
    if (!result.translated.endsWith('\n')) stdout.writeln();

    if (showDetected && from == null && result.detectedFrom != null) {
      stderr.writeln('(detected source: ${result.detectedFrom})');
    }
    return 0;
  }

  /// Parses glossary entries from the inline `--glossary` flag and/or
  /// the `--glossary-file` flag, merging file entries first so inline
  /// values take precedence. Returns null after writing to stderr if
  /// the input is malformed (so the caller can exit 64).
  Map<String, String>? _parseGlossary({
    String? inline,
    String? filePath,
  }) {
    final out = <String, String>{};

    if (filePath != null && filePath.isNotEmpty) {
      final file = File(filePath);
      if (!file.existsSync()) {
        stderr.writeln('translate: --glossary-file not found: $filePath');
        return null;
      }
      for (final raw in file.readAsLinesSync()) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final eq = line.indexOf('=');
        if (eq <= 0) {
          stderr.writeln('translate: malformed glossary line: $raw');
          return null;
        }
        out[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
      }
    }

    if (inline != null && inline.isNotEmpty) {
      for (final pair in inline.split(',')) {
        final p = pair.trim();
        if (p.isEmpty) continue;
        final eq = p.indexOf('=');
        if (eq <= 0) {
          stderr.writeln(
            'translate: malformed --glossary entry: "$p" '
            '(expected source=target).',
          );
          return null;
        }
        out[p.substring(0, eq).trim()] = p.substring(eq + 1).trim();
      }
    }

    return out;
  }
}
