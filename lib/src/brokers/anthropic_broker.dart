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

/// Anthropic Claude (`/v1/messages`). `system` is a top-level field,
/// not a role — keep it out of [ChatRequest.messages].
class AnthropicBroker implements AiBroker {
  static const _baseUrl = 'https://api.anthropic.com/v1';
  static const _apiVersion = '2023-06-01';
  static const _timeout = Duration(seconds: 30);

  final Client _http;

  AnthropicBroker({Client? client}) : _http = client ?? Client();

  @override
  String get id => 'anthropic';

  @override
  String get label => 'Anthropic (Claude)';

  @override
  Future<List<String>> listModels(String apiKey) async {
    if (apiKey.isEmpty) return const [];
    final res = await _http.get(
      Uri.parse('$_baseUrl/models'),
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': _apiVersion,
      },
    ).timeout(_timeout);
    if (res.statusCode >= 400) return const [];
    final body = jsonDecode(res.body) as Map<String, Object?>;
    final data = body['data'] as List<Object?>? ?? const [];
    final ids = <String>[];
    for (final m in data) {
      if (m is! Map<String, Object?>) continue;
      final modelId = m['id'] as String?;
      if (modelId != null) ids.add(modelId);
    }
    // Newest first — `claude-opus-4-7` should land before
    // `claude-3-5-sonnet`. The API already returns this order; sort
    // by id descending to normalise.
    ids.sort((a, b) => b.compareTo(a));
    return ids;
  }

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
    final body = jsonEncode(_buildPayload(model, request, stream: false));
    final res = await retryRequest(
      send: () => _http
          .post(
            Uri.parse('$_baseUrl/messages'),
            headers: _headers(apiKey),
            body: body,
          )
          .timeout(_timeout),
      providerLabel: 'Anthropic',
    );
    final json = jsonDecode(res.body) as Map<String, Object?>;
    final content = json['content'] as List<Object?>?;
    if (content == null || content.isEmpty) {
      throw const AiBrokerException('Anthropic returned no content.');
    }
    final buf = StringBuffer();
    for (final block in content) {
      if (block is! Map<String, Object?>) continue;
      if (block['type'] != 'text') continue;
      buf.write(block['text'] as String? ?? '');
    }
    final out = buf.toString().trim();
    if (out.isEmpty) {
      throw const AiBrokerException('Anthropic returned empty text.');
    }
    return out;
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async* {
    final body = jsonEncode(_buildPayload(model, request, stream: true));
    final byteStream = await openSsePost(
      uri: Uri.parse('$_baseUrl/messages'),
      headers: {
        ..._headers(apiKey),
        'Accept': 'text/event-stream',
      },
      body: body,
      providerLabel: 'Anthropic',
      client: _http,
    );
    // Anthropic stream events:
    //  - content_block_delta → { delta: { type: 'text_delta', text } }
    //  - message_stop → end of stream
    // Other events (message_start, ping, etc.) are ignored here.
    await for (final event in decodeSseStream(byteStream)) {
      if (event.event == 'message_stop') return;
      if (event.event != 'content_block_delta') continue;
      if (event.data.isEmpty) continue;
      final json = jsonDecode(event.data) as Map<String, Object?>;
      final delta = json['delta'] as Map<String, Object?>?;
      if (delta == null) continue;
      if (delta['type'] != 'text_delta') continue;
      final text = delta['text'] as String?;
      if (text != null && text.isNotEmpty) yield text;
    }
  }

  Map<String, String> _headers(String apiKey) => {
        'x-api-key': apiKey,
        'anthropic-version': _apiVersion,
        'Content-Type': 'application/json',
      };

  Map<String, Object?> _buildPayload(
    String model,
    ChatRequest req, {
    required bool stream,
  }) =>
      {
        'model': model,
        'max_tokens': req.maxTokens,
        'temperature': req.temperature,
        'system': req.system,
        'messages': [
          for (final m in req.messages)
            {'role': m.roleName, 'content': m.content},
        ],
        if (stream) 'stream': true,
      };
}
