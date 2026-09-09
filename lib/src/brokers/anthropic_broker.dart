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
///
/// Only implements [ChatBroker]. Anthropic doesn't host first-party
/// embeddings (they partner with Voyage AI); pair Anthropic with
/// [OpenAiBroker] or [GeminiBroker] for the embed side of a RAG
/// pipeline.
class AnthropicBroker extends ChatBroker {
  static const defaultBaseUrl = 'https://api.anthropic.com/v1';
  static const _apiVersion = '2023-06-01';
  static const _timeout = Duration(seconds: 120);

  final Client _http;

  /// Where requests go. Defaults to the real API, overridable by the
  /// `ANTHROPIC_BASE_URL` environment variable and then by the constructor
  /// argument, so a proxy, a gateway or a local test double can be swapped in
  /// without touching call sites.
  final String baseUrl;

  AnthropicBroker({Client? client, String? baseUrl})
      : _http = client ?? Client(),
        baseUrl = baseUrl ??
            (Platform.environment['ANTHROPIC_BASE_URL']?.isNotEmpty ?? false
                ? Platform.environment['ANTHROPIC_BASE_URL']!
                : defaultBaseUrl);

  @override
  String get id => 'anthropic';

  @override
  String get label => 'Anthropic (Claude)';

  @override
  Future<List<String>> listModels(String apiKey) async {
    if (apiKey.isEmpty) return const [];
    final res = await _http.get(
      Uri.parse('$baseUrl/models'),
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
    // `claude-3-5-sonnet`. The API already returns this order; resort
    // with a digit-aware key so that `3-10` ranks above `3-7`
    // (plain lex would put `3-7` first because `'7' > '1'`).
    ids.sort((a, b) => _compareNatural(b, a));
    return ids;
  }

  /// Compares two strings as alternating runs of text and digits, so
  /// `claude-3-10-sonnet` > `claude-3-7-sonnet`. Used for newest-first
  /// model id sorting.
  static int _compareNatural(String a, String b) {
    var i = 0, j = 0;
    while (i < a.length && j < b.length) {
      final aDigit = _isDigit(a.codeUnitAt(i));
      final bDigit = _isDigit(b.codeUnitAt(j));
      if (aDigit && bDigit) {
        var ai = i, bj = j;
        while (ai < a.length && _isDigit(a.codeUnitAt(ai))) {
          ai++;
        }
        while (bj < b.length && _isDigit(b.codeUnitAt(bj))) {
          bj++;
        }
        final an = int.parse(a.substring(i, ai));
        final bn = int.parse(b.substring(j, bj));
        if (an != bn) return an.compareTo(bn);
        i = ai;
        j = bj;
      } else {
        final c = a[i].compareTo(b[j]);
        if (c != 0) return c;
        i++;
        j++;
      }
    }
    return (a.length - i).compareTo(b.length - j);
  }

  static bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

  @override
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    final result = await chatDetailed(
      apiKey: apiKey,
      model: model,
      request: request,
    );
    if (result.text.isEmpty) {
      throw AiBrokerException(
        result.isRefusal
            ? 'Anthropic declined this request (stop_reason: refusal).'
            : 'Anthropic returned empty text.',
      );
    }
    return result.text;
  }

  @override
  Future<AiCompletion> chatDetailed({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async {
    final body = jsonEncode(buildPayload(model, request, stream: false));
    final res = await retryRequest(
      send: () => _http
          .post(
            Uri.parse('$baseUrl/messages'),
            headers: _headers(apiKey),
            body: body,
          )
          .timeout(_timeout),
      providerLabel: 'Anthropic',
    );
    final json = jsonDecode(res.body) as Map<String, Object?>;
    final content = json['content'] as List<Object?>? ?? const [];
    final buf = StringBuffer();
    for (final block in content) {
      if (block is! Map<String, Object?>) continue;
      if (block['type'] != 'text') continue;
      buf.write(block['text'] as String? ?? '');
    }
    final usage = json['usage'] as Map<String, Object?>? ?? const {};
    int count(String key) => (usage[key] as num?)?.toInt() ?? 0;

    // A refusal is a 200 with an empty body, not an exception. Report it as a
    // completion so callers can decide — a chat UI shows a fallback line, a
    // scoring loop records a SKIP.
    return AiCompletion(
      text: buf.toString().trim(),
      model: json['model'] as String? ?? model,
      stopReason: AiStopReason.fromWire(json['stop_reason'] as String?),
      inputTokens: count('input_tokens'),
      outputTokens: count('output_tokens'),
      cacheReadInputTokens: count('cache_read_input_tokens'),
      cacheCreationInputTokens: count('cache_creation_input_tokens'),
    );
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) async* {
    final body = jsonEncode(buildPayload(model, request, stream: true));
    final byteStream = await openSsePost(
      uri: Uri.parse('$baseUrl/messages'),
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

  /// Build the request body.
  ///
  /// What is deliberately absent matters as much as what is present:
  /// `temperature` is only included when the caller explicitly set one,
  /// because current models reject it. Effort and structured output ride in
  /// `output_config`; there is no assistant prefill, which is also rejected.
  @visibleForTesting
  Map<String, Object?> buildPayload(
    String model,
    ChatRequest req, {
    required bool stream,
  }) {
    final outputConfig = <String, Object?>{
      if (req.effort != null) 'effort': req.effort!.wire,
      if (req.jsonSchema != null)
        'format': {'type': 'json_schema', 'schema': req.jsonSchema},
    };
    return {
      'model': model,
      'max_tokens': req.maxTokens,
      // Only when asked for: sending it unconditionally 400s on every
      // current model.
      if (req.temperature != null) 'temperature': req.temperature,
      if (req.system.isNotEmpty)
        'system': req.cacheSystem
            // Block form is the only way to attach a cache breakpoint.
            ? [
                {
                  'type': 'text',
                  'text': req.system,
                  'cache_control': {'type': 'ephemeral'},
                },
              ]
            : req.system,
      'messages': [
        for (final m in req.messages)
          {'role': m.roleName, 'content': m.content},
      ],
      if (outputConfig.isNotEmpty) 'output_config': outputConfig,
      if (stream) 'stream': true,
    };
  }
}
