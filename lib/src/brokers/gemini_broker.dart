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

/// Google Gemini (`generateContent` / `streamGenerateContent`).
/// Pagination on listModels caps at 5 pages × 50; only `gemini-*` ids
/// that support `generateContent` are kept.
///
/// Gemini's streaming endpoint uses SSE in `?alt=sse` mode — without
/// that, the response is a JSON array of objects, which is unfriendly
/// to chunked parsing. We force SSE so we can share the SSE decoder
/// with the other brokers.
class GeminiBroker extends ChatBroker implements EmbedBroker {
  /// Recommended default for [embed]. 768-d, free tier available.
  static const defaultEmbedModel = 'text-embedding-004';

  static const _baseUrl = 'https://generativelanguage.googleapis.com/v1beta';
  static const _timeout = Duration(seconds: 30);

  final Client _http;

  GeminiBroker({Client? client}) : _http = client ?? Client();

  @override
  String get id => 'gemini';

  @override
  String get label => 'Google (Gemini)';

  @override
  Future<List<String>> listModels(String apiKey) async {
    if (apiKey.isEmpty) return const [];
    final ids = <String>{};
    String? pageToken;
    for (var page = 0; page < 5; page++) {
      final query = <String, String>{
        'pageSize': '50',
        if (pageToken != null) 'pageToken': pageToken,
      };
      final uri = Uri.parse('$_baseUrl/models').replace(queryParameters: query);
      final res =
          await _http.get(uri, headers: _authHeaders(apiKey)).timeout(_timeout);
      if (res.statusCode >= 400) return const [];
      final body = jsonDecode(res.body) as Map<String, Object?>;
      final models = body['models'] as List<Object?>? ?? const [];
      for (final m in models) {
        if (m is! Map<String, Object?>) continue;
        final name = m['name'] as String?;
        if (name == null) continue;
        final bare = name.startsWith('models/') ? name.substring(7) : name;
        if (!bare.startsWith('gemini-')) continue;
        final methods =
            (m['supportedGenerationMethods'] as List<Object?>?) ?? const [];
        if (!methods.contains('generateContent')) continue;
        ids.add(bare);
      }
      pageToken = body['nextPageToken'] as String?;
      if (pageToken == null || pageToken.isEmpty) break;
    }
    return ids.toList()..sort((a, b) => b.compareTo(a));
  }

  @override
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    final uri = Uri.parse('$_baseUrl/models/$model:generateContent');
    final body = jsonEncode(_buildPayload(request));
    final res = await retryRequest(
      send: () => _http
          .post(
            uri,
            headers: {
              ..._authHeaders(apiKey),
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(_timeout),
      providerLabel: 'Gemini',
    );
    final json = jsonDecode(res.body) as Map<String, Object?>;
    return _extractText(json);
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async* {
    final uri = Uri.parse('$_baseUrl/models/$model:streamGenerateContent')
        .replace(queryParameters: {'alt': 'sse'});
    final body = jsonEncode(_buildPayload(request));
    final byteStream = await openSsePost(
      uri: uri,
      headers: {
        ..._authHeaders(apiKey),
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      },
      body: body,
      providerLabel: 'Gemini',
      client: _http,
    );
    await for (final event in decodeSseStream(byteStream)) {
      if (event.data.isEmpty) continue;
      final json = jsonDecode(event.data) as Map<String, Object?>;
      final text = _extractText(json, allowEmpty: true);
      if (text.isNotEmpty) yield text;
    }
  }

  /// Pulls text out of either a `generateContent` response or a
  /// `streamGenerateContent` chunk. They share the same `candidates →
  /// content → parts → text` shape, so one extractor handles both.
  String _extractText(Map<String, Object?> json, {bool allowEmpty = false}) {
    final candidates = json['candidates'] as List<Object?>? ?? const [];
    if (candidates.isEmpty) {
      if (allowEmpty) return '';
      throw const AiBrokerException('Gemini returned no candidates.');
    }
    final first = candidates.first as Map<String, Object?>;
    final content = first['content'] as Map<String, Object?>?;
    final parts = content?['parts'] as List<Object?>? ?? const [];
    final buf = StringBuffer();
    for (final p in parts) {
      if (p is! Map<String, Object?>) continue;
      buf.write(p['text'] as String? ?? '');
    }
    final out = buf.toString();
    if (out.isEmpty && !allowEmpty) {
      throw const AiBrokerException('Gemini returned empty text.');
    }
    return out;
  }

  @override
  Future<List<List<double>>> embed({
    required String apiKey,
    required String model,
    required List<String> inputs,
  }) async {
    if (inputs.isEmpty) return const [];
    // Gemini wants the model name prefixed with `models/` in each request
    // *and* in the URL path.
    final modelPath = model.startsWith('models/') ? model : 'models/$model';
    final body = jsonEncode({
      'requests': [
        for (final text in inputs)
          {
            'model': modelPath,
            'content': {
              'parts': [
                {'text': text},
              ],
            },
          },
      ],
    });
    final uri = Uri.parse('$_baseUrl/$modelPath:batchEmbedContents');
    final res = await retryRequest(
      send: () => _http
          .post(
            uri,
            headers: {
              ..._authHeaders(apiKey),
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(_timeout),
      providerLabel: 'Gemini',
    );
    final json = jsonDecode(res.body) as Map<String, Object?>;
    final embeddings = json['embeddings'] as List<Object?>?;
    if (embeddings == null || embeddings.isEmpty) {
      throw const AiBrokerException('Gemini returned no embeddings.');
    }
    final out = <List<double>>[];
    for (final item in embeddings) {
      final m = item as Map<String, Object?>;
      final values = m['values'] as List<Object?>?;
      if (values == null) {
        throw const AiBrokerException('Gemini embedding missing values.');
      }
      out.add(
        values.map((v) => (v as num).toDouble()).toList(growable: false),
      );
    }
    if (out.length != inputs.length) {
      throw AiBrokerException(
        'Gemini returned ${out.length} embeddings for ${inputs.length} inputs.',
      );
    }
    return out;
  }

  Map<String, String> _authHeaders(String apiKey) => {
        'x-goog-api-key': apiKey,
      };

  Map<String, Object?> _buildPayload(ChatRequest req) => {
        if (req.system.isNotEmpty)
          'systemInstruction': {
            'parts': [
              {'text': req.system},
            ],
          },
        'contents': [
          for (final m in req.messages)
            {
              'role': m.role == AiRole.user ? 'user' : 'model',
              'parts': [
                {'text': m.content},
              ],
            },
        ],
        'generationConfig': {
          'temperature': req.temperature,
          'maxOutputTokens': req.maxTokens,
        },
      };
}
