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

/// Translation capability. Implemented natively by
/// `GoogleTranslateBroker` (Google Cloud Translation v2). Any
/// `ChatBroker` can also be wrapped in `LlmTranslator` to act as a
/// [TranslateBroker] powered by an LLM — useful when context matters
/// and the dedicated translation service isn't available.
///
/// All hint parameters ([domain], [tone], [glossary], [context]) are
/// optional and provider-best-effort: LLM translators incorporate them
/// into the system prompt; Google Translate uses the glossary via
/// HTML `translate="no"` wrapping and ignores the other hints.
abstract class TranslateBroker implements AiBroker {
  /// Translates [text] into [to]. If [from] is null, the implementation
  /// detects the source language and returns it in
  /// [TranslationResult.detectedFrom].
  ///
  /// Hints (all optional):
  /// - [domain]: free-form domain label, e.g. `"medical"`, `"legal"`.
  /// - [tone]: e.g. `"formal"`, `"casual"`. Influences pronouns and
  ///   verb forms in languages where it matters.
  /// - [glossary]: source-term → preferred-translation map. Honoured
  ///   exactly where supported (LLM translators get this as a prompt
  ///   directive; Google Translate uses HTML `translate="no"` markup).
  /// - [context]: free-form additional context (surrounding text,
  ///   stylistic notes, anything the LLM should know).
  /// - [model]: provider-specific model override.
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
  });
}

/// Output of [TranslateBroker.translate]. [translated] is always set;
/// [detectedFrom] is non-null when the caller passed `from: null` and
/// the provider reported a detected source language; [modelUsed] is
/// set when the implementation routed through a specific model
/// (LLM translators) and null otherwise.
@immutable
class TranslationResult {
  final String translated;
  final String? detectedFrom;
  final String? modelUsed;

  const TranslationResult({
    required this.translated,
    this.detectedFrom,
    this.modelUsed,
  });

  @override
  String toString() =>
      'TranslationResult($translated, detectedFrom=$detectedFrom, modelUsed=$modelUsed)';
}
