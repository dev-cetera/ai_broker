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

  /// Chat requests are not quick calls. A reasoning model doing a structured
  /// judge over a knowledge bundle measured 21.5s here on a synthetic input and
  /// more on a real one, so the old 30s cut them off mid-thought and surfaced
  /// as a bare TimeoutException far from the cause. Matches the Anthropic
  /// broker, which was raised for exactly this reason in 0.4.0.
  static const _timeout = Duration(seconds: 120);

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
    final body = jsonEncode(buildPayload(request));
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
  }) =>
      streamDetailed(apiKey: apiKey, model: model, request: request).deltas;

  @override
  StreamedCompletion streamDetailed({
    required String apiKey,
    required String model,
    required ChatRequest request,
  }) {
    final completer = Completer<AiCompletion>();
    // A caller that only drains the text — every `stream()` call — already
    // sees a failure on the stream itself; without a listener here the same
    // error would also surface as an unhandled async error.
    completer.future.ignore();
    return StreamedCompletion(
      deltas: _streamDeltas(
        apiKey: apiKey,
        model: model,
        request: request,
        completer: completer,
      ),
      completion: completer.future,
    );
  }

  /// The SSE read loop behind [stream] and [streamDetailed]. Gemini repeats
  /// `usageMetadata` on chunks and settles it on the last one, so the running
  /// values are simply overwritten as they arrive.
  Stream<String> _streamDeltas({
    required String apiKey,
    required String model,
    required ChatRequest request,
    required Completer<AiCompletion> completer,
  }) async* {
    final buf = StringBuffer();
    var servingModel = model;
    var stopReason = AiStopReason.unknown;
    var inputTokens = 0;
    var outputTokens = 0;
    var cachedTokens = 0;

    Iterable<String> consume(SseEvent event) sync* {
      if (event.data.isEmpty) return;
      final json = jsonDecode(event.data) as Map<String, Object?>;
      servingModel = json['modelVersion'] as String? ?? servingModel;
      final usage = json['usageMetadata'] as Map<String, Object?>?;
      if (usage != null) {
        int? at(String key) => (usage[key] as num?)?.toInt();
        inputTokens = at('promptTokenCount') ?? inputTokens;
        outputTokens = at('candidatesTokenCount') ?? outputTokens;
        cachedTokens = at('cachedContentTokenCount') ?? cachedTokens;
      }
      final candidates = json['candidates'] as List<Object?>? ?? const [];
      if (candidates.isNotEmpty) {
        final first = candidates.first as Map<String, Object?>;
        final finish = first['finishReason'] as String?;
        if (finish != null) stopReason = _stopReasonFrom(finish);
      }
      final text = _extractText(json, allowEmpty: true);
      if (text.isEmpty) return;
      buf.write(text);
      yield text;
    }

    try {
      final uri = Uri.parse('$_baseUrl/models/$model:streamGenerateContent')
          .replace(queryParameters: {'alt': 'sse'});
      final body = jsonEncode(buildPayload(request));
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
      // `yield*` rather than `await for`, so a consumer that cancels
      // mid-reply is acknowledged at once and the `finally` below still
      // runs. Stream errors bypass the enclosing catch as a result, hence
      // the `handleError` hop.
      yield* decodeSseStream(byteStream).expand(consume).handleError(
        (Object e, StackTrace st) {
          if (!completer.isCompleted) completer.completeError(e, st);
          Error.throwWithStackTrace(e, st);
        },
      );
    } catch (e, st) {
      // Connection failures and non-2xx responses, which throw before the
      // first event arrives.
      if (!completer.isCompleted) completer.completeError(e, st);
      rethrow;
    } finally {
      // Also the cancellation path: a consumer that walks away mid-reply gets
      // a completion for the part that did arrive rather than a hung future.
      if (!completer.isCompleted) {
        completer.complete(
          AiCompletion(
            text: buf.toString().trim(),
            model: servingModel,
            stopReason: stopReason,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cachedTokens,
          ),
        );
      }
    }
  }

  /// Gemini has its own vocabulary for why generation stopped. Map it onto
  /// the shared [AiStopReason] so callers branch identically across
  /// providers — in particular, every safety stop reads as a refusal.
  static AiStopReason _stopReasonFrom(String finishReason) {
    switch (finishReason) {
      case 'STOP':
        return AiStopReason.endTurn;
      case 'MAX_TOKENS':
        return AiStopReason.maxTokens;
      case 'SAFETY':
      case 'RECITATION':
      case 'BLOCKLIST':
      case 'PROHIBITED_CONTENT':
      case 'SPII':
      case 'IMAGE_SAFETY':
        return AiStopReason.refusal;
      default:
        return AiStopReason.unknown;
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

  /// Build the request body. Shared by [chat] and the streaming read loop, so
  /// structured output behaves identically on both.
  ///
  /// [ChatRequest.jsonSchema] rides in `generationConfig`. Two fields, not
  /// one: `responseMimeType` is what actually forces JSON instead of prose,
  /// and `responseSchema` constrains its shape. Gemini speaks an OpenAPI 3.0
  /// subset rather than JSON Schema — forwarding the caller's schema unchanged
  /// is a 400 (`Unknown name "additionalProperties"`), so it goes through
  /// [toGeminiSchema] first. When no safe translation exists that returns
  /// null and only the mime type is sent: unconstrained JSON is still JSON,
  /// which beats both prose and a rejected request.
  @visibleForTesting
  Map<String, Object?> buildPayload(ChatRequest req) {
    final schema = req.jsonSchema;
    final responseSchema = schema == null ? null : toGeminiSchema(schema);
    return {
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
        if (schema != null) 'responseMimeType': 'application/json',
        if (responseSchema != null) 'responseSchema': responseSchema,
      },
    };
  }
}
