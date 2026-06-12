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

import '/_common.dart';

/// Wraps any [ChatBroker] so it can be used wherever a
/// [TranslateBroker] is expected. The translation request is converted
/// into a system prompt that includes the target language plus every
/// supplied hint (domain, tone, glossary, free-form context).
///
/// The class itself implements [TranslateBroker] — register it under
/// an id like `'llm:openai'` or pass it directly to a CLI command.
///
/// LLM translation generally outperforms dedicated MT engines on
/// context-sensitive content (technical docs with consistent
/// terminology, multi-sentence passages where pronouns refer back, any
/// case where tone matters). The trade-off is cost and latency —
/// translation via Claude / GPT-4 / Gemini costs orders of magnitude
/// more per character than Google Cloud Translation and is slower.
class LlmTranslator implements TranslateBroker {
  /// The underlying chat broker. Anything that implements [ChatBroker]
  /// works (`OpenAiBroker`, `AnthropicBroker`, `GeminiBroker`, or a
  /// custom one).
  final ChatBroker chatBroker;

  /// Fallback model when [translate] is called without an explicit
  /// `model:` argument.
  final String defaultModel;

  /// Optional id override — defaults to `'llm:<chatBroker.id>'` so
  /// `OpenAiBroker` → `'llm:openai'`. Useful when registering multiple
  /// `LlmTranslator` instances against the same chat provider.
  final String? idOverride;

  const LlmTranslator({
    required this.chatBroker,
    required this.defaultModel,
    this.idOverride,
  });

  @override
  String get id => idOverride ?? 'llm:${chatBroker.id}';

  @override
  String get label => 'LLM translator (${chatBroker.label})';

  @override
  Future<List<String>> listModels(String apiKey) =>
      chatBroker.listModels(apiKey);

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
    final usedModel = model ?? defaultModel;
    final systemPrompt = _buildSystemPrompt(
      to: to,
      from: from,
      domain: domain,
      tone: tone,
      glossary: glossary,
      context: context,
    );
    final answer = await chatBroker.complete(
      apiKey: apiKey,
      model: usedModel,
      system: systemPrompt,
      user: text,
      // Translation should be ~deterministic — low temperature, but not
      // zero (some providers behave poorly at exactly 0).
      temperature: 0.1,
      // Translations can be longer than the source (verbose languages,
      // glossary expansions). Give a comfortable ceiling.
      maxTokens: 4096,
    );
    return TranslationResult(
      translated: answer.trim(),
      modelUsed: usedModel,
    );
  }

  String _buildSystemPrompt({
    required String to,
    String? from,
    String? domain,
    String? tone,
    Map<String, String>? glossary,
    String? context,
  }) {
    final buf = StringBuffer()
      ..write(
        'You are a precise, context-aware translator. Translate the user '
        'message',
      );
    if (from != null) buf.write(' from $from');
    buf
      ..writeln(' to $to.')
      ..writeln();

    if (domain != null && domain.isNotEmpty) {
      buf.writeln('Domain: $domain.');
    }
    if (tone != null && tone.isNotEmpty) {
      buf.writeln(
        'Tone: $tone. Match register, pronouns, and verb forms accordingly.',
      );
    }
    if (context != null && context.isNotEmpty) {
      buf
        ..writeln('Additional context:')
        ..writeln(context);
    }
    if (glossary != null && glossary.isNotEmpty) {
      buf
        ..writeln()
        ..writeln(
          'Glossary — when these source terms appear, the translation '
          'MUST use the exact target text shown:',
        );
      for (final e in glossary.entries) {
        buf.writeln('  "${e.key}" → "${e.value}"');
      }
    }

    buf
      ..writeln()
      ..writeln('Rules:')
      ..writeln('- Output ONLY the translated text, no commentary, no quotes.')
      ..writeln(
        '- Preserve original formatting (line breaks, lists, code blocks).',
      )
      ..writeln(
        '- If the source is already in the target language, return it '
        'unchanged.',
      );
    return buf.toString();
  }
}
