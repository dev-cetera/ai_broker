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

/// OpenAI provider — implements [ChatBroker] (`/v1/chat/completions`)
/// and [EmbedBroker] (`/v1/embeddings`). Filters [listModels] to
/// `gpt-*` / `o<digit>*` so the picker doesn't show whisper /
/// embeddings / dall-e.
class OpenAiBroker extends ChatBroker implements EmbedBroker {
  /// Recommended default for [embed]. 1536-d, cheap, well-supported.
  static const defaultEmbedModel = 'text-embedding-3-small';

  static const _baseUrl = 'https://api.openai.com/v1';
  static const _timeout = Duration(seconds: 30);
  static final _chatModelPattern = RegExp(r'^(gpt-|o\d)');

  final Client _http;

  OpenAiBroker({Client? client}) : _http = client ?? Client();

  @override
  String get id => 'openai';

  @override
  String get label => 'OpenAI';

  @override
  Future<List<String>> listModels(String apiKey) async {
    if (apiKey.isEmpty) return const [];
    final res = await _http.get(
      Uri.parse('$_baseUrl/models'),
      headers: {'Authorization': 'Bearer $apiKey'},
    ).timeout(_timeout);
    if (res.statusCode >= 400) return const [];
    final body = jsonDecode(res.body) as Map<String, Object?>;
    final data = body['data'] as List<Object?>? ?? const [];
    final ids = <String>[];
    for (final m in data) {
      if (m is! Map<String, Object?>) continue;
      final modelId = m['id'] as String?;
      if (modelId == null) continue;
      if (!_chatModelPattern.hasMatch(modelId)) continue;
      ids.add(modelId);
    }
    ids.sort();
    return ids;
  }

  @override
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    final body = jsonEncode(_buildPayload(model, request, stream: false));
    final res = await retryRequest(
      send: () => _http
          .post(
            Uri.parse('$_baseUrl/chat/completions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(_timeout),
      providerLabel: 'OpenAI',
      isHardFailure: (r) =>
          r.statusCode == 429 && r.body.toLowerCase().contains('quota'),
    );
    final json = jsonDecode(res.body) as Map<String, Object?>;
    final choices = json['choices'] as List<Object?>?;
    if (choices == null || choices.isEmpty) {
      throw const AiBrokerException('OpenAI returned no choices.');
    }
    final first = choices.first as Map<String, Object?>;
    final message = first['message'] as Map<String, Object?>?;
    final content = message?['content'] as String?;
    if (content == null || content.isEmpty) {
      throw const AiBrokerException('OpenAI returned empty content.');
    }
    return content.trim();
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async* {
    final body = jsonEncode(_buildPayload(model, request, stream: true));
    final byteStream = await openSsePost(
      uri: Uri.parse('$_baseUrl/chat/completions'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      },
      body: body,
      providerLabel: 'OpenAI',
      client: _http,
    );
    await for (final event in decodeSseStream(byteStream)) {
      final data = event.data;
      if (data == '[DONE]') return;
      if (data.isEmpty) continue;
      final json = jsonDecode(data) as Map<String, Object?>;
      final choices = json['choices'] as List<Object?>? ?? const [];
      if (choices.isEmpty) continue;
      final delta = (choices.first as Map<String, Object?>)['delta']
          as Map<String, Object?>?;
      final content = delta?['content'] as String?;
      if (content != null && content.isNotEmpty) yield content;
    }
  }

  Map<String, Object?> _buildPayload(
    String model,
    ChatRequest req, {
    required bool stream,
  }) =>
      {
        'model': model,
        'messages': [
          if (req.system.isNotEmpty) {'role': 'system', 'content': req.system},
          for (final m in req.messages)
            {'role': m.roleName, 'content': m.content},
        ],
        'temperature': req.temperature,
        'max_tokens': req.maxTokens,
        if (stream) 'stream': true,
      };

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
      send: () => _http
          .post(
            Uri.parse('$_baseUrl/embeddings'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(_timeout),
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
