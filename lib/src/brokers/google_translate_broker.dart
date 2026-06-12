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

/// Google Cloud Translation v2 (`/language/translate/v2`). Uses simple
/// API-key auth — no service-account JSON. Cloud Translation is a
/// separate service from Gemini and uses a different API key issued
/// from the Google Cloud Console with the Cloud Translation API
/// enabled.
///
/// Only implements [TranslateBroker]. Does not chat, embed, or list
/// chat models — `listModels` returns the empty list.
///
/// ### Glossary handling
///
/// Cloud Translation v2 doesn't expose the v3 server-side glossary
/// resource, so glossary support is implemented **client-side** with
/// HTML wrapping. Each glossary entry `"source" → "target"` becomes a
/// `<span translate="no">target</span>` substituted into the input
/// before translation, sent with `format: 'html'` so the markup is
/// preserved end-to-end. The spans are stripped from the response and
/// the standard HTML entities Google emits (`&amp;`, `&lt;`, `&gt;`,
/// `&quot;`, `&#39;`, numeric `&#NN;`) are decoded back to plain text.
///
/// Source text and glossary targets are HTML-escaped before wrapping
/// so `<`, `>`, `&` in the input round-trip cleanly through `format:
/// 'html'`.
///
/// Caveats:
/// - **Exact, case-sensitive substring match.** "BME280" matches but
///   "Bme280" doesn't. Provide every casing you care about.
/// - **Substring matching can fire inside words.** Putting "act" in
///   the glossary will also affect "react". Use longer, distinctive
///   terms (proper nouns, IDs).
/// - **Overlap resolution.** When two glossary keys could match at
///   the same position, the longer one wins; otherwise the
///   earliest-starting match wins. Map iteration order doesn't matter.
class GoogleTranslateBroker implements TranslateBroker {
  static const _baseUrl = 'https://translation.googleapis.com';
  static const _timeout = Duration(seconds: 30);

  final Client _http;

  GoogleTranslateBroker({Client? client}) : _http = client ?? Client();

  @override
  String get id => 'google_translate';

  @override
  String get label => 'Google (Translate)';

  /// Cloud Translation v2 has no equivalent of `/models` — translation
  /// models aren't a user-facing pickable resource. Always returns the
  /// empty list.
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
    // Domain / tone / context aren't representable in v2 — silently
    // accepted (the contract is best-effort). Use LlmTranslator if
    // these matter.

    final hasGlossary = glossary != null && glossary.isNotEmpty;
    final input = hasGlossary ? _applyGlossary(text, glossary) : text;
    final format = hasGlossary ? 'html' : 'text';

    final body = jsonEncode({
      'q': input,
      'target': to,
      if (from != null) 'source': from,
      'format': format,
      if (model != null) 'model': model,
    });

    final res = await retryRequest(
      send: () => _http
          .post(
            Uri.parse('$_baseUrl/language/translate/v2?key=$apiKey'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(_timeout),
      providerLabel: 'Google Translate',
    );
    final json = jsonDecode(res.body) as Map<String, Object?>;
    final data = json['data'] as Map<String, Object?>?;
    final translations = data?['translations'] as List<Object?>?;
    if (translations == null || translations.isEmpty) {
      throw const AiBrokerException(
        'Google Translate returned no translations.',
      );
    }
    final first = translations.first as Map<String, Object?>;
    final raw = first['translatedText'] as String?;
    if (raw == null) {
      throw const AiBrokerException(
        'Google Translate response missing translatedText.',
      );
    }
    final cleaned = hasGlossary ? _stripNotranslateSpans(raw) : raw;
    return TranslationResult(
      translated: cleaned,
      detectedFrom: first['detectedSourceLanguage'] as String?,
    );
  }

  /// Wraps each glossary source-term occurrence with
  /// `<span translate="no">target</span>`. On overlap the longer key
  /// wins at the same position; otherwise the earliest-starting match
  /// wins. Map iteration order is not consulted.
  ///
  /// In glossary mode the request goes out as `format: 'html'`, so
  /// `<`, `>`, `&` in the source text (or in glossary targets) would
  /// be interpreted as markup. Non-glossary segments are HTML-escaped
  /// here; glossary targets are escaped inside their span. A single
  /// scan walks the text and emits escaped chunks + spans in order.
  String _applyGlossary(String text, Map<String, String> glossary) {
    final terms = [
      for (final e in glossary.entries)
        if (e.key.isNotEmpty) e,
    ];
    if (terms.isEmpty) return _escapeHtml(text);

    final buf = StringBuffer();
    var i = 0;
    while (i < text.length) {
      // Find the earliest match across all terms at position i. Tie-break
      // by longer term (more-specific wins on overlap).
      int? bestStart;
      MapEntry<String, String>? bestEntry;
      for (final term in terms) {
        final idx = text.indexOf(term.key, i);
        if (idx < 0) continue;
        if (bestStart == null ||
            idx < bestStart ||
            (idx == bestStart && term.key.length > bestEntry!.key.length)) {
          bestStart = idx;
          bestEntry = term;
        }
      }
      if (bestStart == null || bestEntry == null) {
        buf.write(_escapeHtml(text.substring(i)));
        break;
      }
      if (bestStart > i) {
        buf.write(_escapeHtml(text.substring(i, bestStart)));
      }
      buf
        ..write('<span translate="no">')
        ..write(_escapeHtml(bestEntry.value))
        ..write('</span>');
      i = bestStart + bestEntry.key.length;
    }
    return buf.toString();
  }

  static final _notranslateRe =
      RegExp(r'<span\s+translate="no">(.*?)</span>', dotAll: true);

  /// Removes the `<span translate="no">…</span>` wrappers added by
  /// [_applyGlossary] and decodes the HTML entities Google emits when
  /// responding to an `html`-format request. Without the decode pass,
  /// `'the catalyst & oxide'` would come back as `'… &amp; …'`.
  String _stripNotranslateSpans(String html) {
    final unwrapped = html.replaceAllMapped(_notranslateRe, (m) => m.group(1)!);
    return _unescapeHtml(unwrapped);
  }

  static String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  static final _entityRe = RegExp(
    r'&(amp|lt|gt|quot|apos|nbsp|#[xX][0-9a-fA-F]+|#\d+);',
  );

  /// Decodes the entity set Google Translate actually emits. Single
  /// pass so `&amp;lt;` decodes to `&lt;` (not `&<`) — each match is
  /// replaced exactly once, left-to-right. Not a full HTML entity
  /// decoder; only the handful the `format: 'html'` path produces in
  /// practice.
  static String _unescapeHtml(String s) {
    return s.replaceAllMapped(_entityRe, (m) {
      final name = m.group(1)!;
      switch (name) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
        case 'nbsp':
          return ' ';
      }
      // Numeric: `#xHH...` (hex) or `#NN...` (decimal).
      final body = name.substring(1);
      final code = body.startsWith('x') || body.startsWith('X')
          ? int.tryParse(body.substring(1), radix: 16)
          : int.tryParse(body);
      if (code == null) return m.group(0)!;
      return String.fromCharCode(code);
    });
  }
}
