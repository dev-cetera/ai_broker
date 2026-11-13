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

/// OpenAI provider — implements [ChatBroker] (`/v1/chat/completions`),
/// [EmbedBroker] (`/v1/embeddings`) and [KeyCheckBroker]. A preset of
/// [OpenAiCompatibleBroker]. Filters [listModels] to `gpt-*` / `o<digit>*`
/// so the picker doesn't show whisper / embeddings / dall-e.
///
/// The token ceiling is sent as `max_completion_tokens` (`max_tokens` is
/// deprecated and rejected by o-series models). Leave
/// [ChatRequest.temperature] unset for reasoning models, and use
/// [ChatRequest.effort] (`reasoning_effort`) instead.
class OpenAiBroker extends OpenAiCompatibleBroker implements EmbedBroker {
  /// Recommended default for [embed]. 1536-d, cheap, well-supported.
  static const defaultEmbedModel = 'text-embedding-3-small';

  static final _chatModelPattern = RegExp(r'^(gpt-|o\d)');

  OpenAiBroker({super.client, String? baseUrl})
      : super(
          id: 'openai',
          label: 'OpenAI',
          baseUrl: baseUrl ?? 'https://api.openai.com/v1',
          modelFilter: _chatModelPattern.hasMatch,
          maxTokensField: 'max_completion_tokens',
        );

  @override
  Future<List<List<double>>> embed({
    required String apiKey,
    required String model,
    required List<String> inputs,
  }) async {
    if (inputs.isEmpty) return const [];
    final body = jsonEncode({
      'model': model,
      'input': inputs,
      'encoding_format': 'float',
    });
    final res = await retryRequest(
      send: () => httpClient
          .post(
            Uri.parse('$baseUrl/embeddings'),
            headers: {
              ...authHeaders(apiKey),
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(timeout),
      providerLabel: 'OpenAI',
      isHardFailure: (r) =>
          r.statusCode == 429 && r.body.toLowerCase().contains('quota'),
    );
    final json = jsonDecode(res.body) as Map<String, Object?>;
    final data = json['data'] as List<Object?>?;
    if (data == null || data.isEmpty) {
      throw const AiBrokerException('OpenAI returned no embeddings.');
    }
    // Sort by index defensively; the API documents request order but
    // pinning it locally costs nothing and protects against future churn.
    final sorted = [...data]..sort((a, b) {
        final ai = (a as Map<String, Object?>)['index'] as int? ?? 0;
        final bi = (b as Map<String, Object?>)['index'] as int? ?? 0;
        return ai.compareTo(bi);
      });
    final out = <List<double>>[];
    for (final item in sorted) {
      final m = item as Map<String, Object?>;
      final embedding = m['embedding'] as List<Object?>?;
      if (embedding == null) {
        throw const AiBrokerException('OpenAI embedding missing.');
      }
      out.add(
        embedding.map((v) => (v as num).toDouble()).toList(growable: false),
      );
    }
    if (out.length != inputs.length) {
      throw AiBrokerException(
        'OpenAI returned ${out.length} embeddings for ${inputs.length} inputs.',
      );
    }
    return out;
  }
}
