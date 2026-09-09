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
    final result = await chatDetailed(
      apiKey: apiKey,
      model: model,
      request: request,
    );
    if (result.text.isEmpty) {
      // A turn that is nothing but `functionCall` parts has no text, and
      // `chat` has no way to return a call — so say which method does.
      throw AiBrokerException(
        toolNoTextMessage('Gemini', 'empty text', result.toolCalls),
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
    // Throws on an empty `candidates` array, which is a real failure at any
    // detail level — there is no turn to report.
    final text = _extractText(json, allowEmpty: true, requireCandidates: true);
    final toolCalls = <AiToolCall>[];
    collectToolCalls(json, toolCalls);
    final usage = json['usageMetadata'] as Map<String, Object?>? ?? const {};
    int count(String key) => (usage[key] as num?)?.toInt() ?? 0;
    final candidates = json['candidates'] as List<Object?>? ?? const [];
    final finish = candidates.isEmpty
        ? null
        : (candidates.first as Map<String, Object?>)['finishReason'] as String?;
    return AiCompletion(
      text: text.trim(),
      model: json['modelVersion'] as String? ?? model,
      // Gemini reports `STOP` even when the whole turn is a function call —
      // it has no `tool_use` finish reason to report. The calls themselves are
      // the only signal, so they are what decides here. Anthropic and OpenAI
      // both say so on the wire and are taken at their word.
      stopReason: toolCalls.isNotEmpty
          ? AiStopReason.toolUse
          : _stopReasonFrom(finish ?? ''),
      inputTokens: count('promptTokenCount'),
      outputTokens: count('candidatesTokenCount'),
      cacheReadInputTokens: count('cachedContentTokenCount'),
      toolCalls: toolCalls,
    );
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
    // Gemini streams a `functionCall` part whole rather than in JSON
    // fragments, so each chunk contributes zero or more finished calls and
    // they simply accumulate in arrival order.
    final toolCalls = <AiToolCall>[];

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
      collectToolCalls(json, toolCalls);
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
            // Same normalisation as `chatDetailed`: Gemini's `finishReason`
            // never says `tool_use`, so the calls are what decides.
            stopReason:
                toolCalls.isNotEmpty ? AiStopReason.toolUse : stopReason,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cachedTokens,
            toolCalls: [...toolCalls],
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
  String _extractText(
    Map<String, Object?> json, {
    bool allowEmpty = false,
    bool requireCandidates = false,
  }) {
    final candidates = json['candidates'] as List<Object?>? ?? const [];
    if (candidates.isEmpty) {
      if (allowEmpty && !requireCandidates) return '';
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
  /// [ChatRequest.tools] rides in a **single** `tools` entry holding every
  /// declaration — `tools: [{functionDeclarations: [...]}]` — not one entry
  /// per tool the way the other two providers spell it. `parameters` takes the
  /// same OpenAPI-3 subset as `responseSchema`, so it goes through
  /// [toGeminiSchema] as well; a schema with no safe translation is sent
  /// without `parameters` rather than 400ing the whole request.
  @visibleForTesting
  Map<String, Object?> buildPayload(ChatRequest req) {
    final schema = req.jsonSchema;
    final responseSchema = schema == null ? null : toGeminiSchema(schema);
    final tools = req.tools;
    final hasTools = tools != null && tools.isNotEmpty;
    return {
      if (req.system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': req.system},
          ],
        },
      'contents': _renderContents(req.messages),
      if (hasTools)
        'tools': [
          {
            'functionDeclarations': [
              for (final tool in tools)
                {
                  'name': tool.name,
                  'description': tool.description,
                  if (toGeminiSchema(tool.inputSchema) case final params?)
                    'parameters': params,
                },
            ],
          },
        ],
      if (hasTools && req.toolChoice != null)
        'toolConfig': {
          'functionCallingConfig': {'mode': _toolMode(req.toolChoice!)},
        },
      'generationConfig': {
        'temperature': req.temperature,
        'maxOutputTokens': req.maxTokens,
        if (schema != null) 'responseMimeType': 'application/json',
        if (responseSchema != null) 'responseSchema': responseSchema,
      },
    };
  }

  /// Gemini's modes are upper-case, and "you must call something" is `ANY`.
  static String _toolMode(AiToolChoice choice) {
    switch (choice) {
      case AiToolChoice.auto:
        return 'AUTO';
      case AiToolChoice.none:
        return 'NONE';
      case AiToolChoice.required:
        return 'ANY';
    }
  }

  /// Renders the turn history into Gemini's `contents`.
  ///
  /// Plain turns keep the single-`text`-part shape they have always had, so a
  /// request without tools is byte-for-byte what earlier versions sent. A
  /// tool-use turn becomes `functionCall` parts on a `model` content; results
  /// become `functionResponse` parts, and **consecutive results are coalesced
  /// into one `user` content** because they answer one model turn.
  ///
  /// The wrinkle is naming: `functionResponse` is keyed by function *name*,
  /// not by call id, and Gemini never sent an id to begin with. The name is
  /// recovered from the assistant turn that asked for the call — which has to
  /// be in the history anyway — and failing that, decoded back out of the
  /// synthesised id.
  static List<Map<String, Object?>> _renderContents(List<AiMessage> messages) {
    final out = <Map<String, Object?>>[];
    var i = 0;
    while (i < messages.length) {
      final message = messages[i];
      if (message.isToolResult) {
        final parts = <Object?>[];
        while (i < messages.length && messages[i].isToolResult) {
          final result = messages[i];
          parts.add({
            'functionResponse': {
              'name': _toolNameFor(result.toolCallId!, messages),
              // Gemini takes an arbitrary object here. Keying an error
              // differently is the only way to say "this failed" on a wire
              // format with no `is_error` flag.
              'response': result.isError
                  ? {'error': result.content}
                  : {'result': result.content},
            },
          });
          i++;
        }
        out.add({'role': 'user', 'parts': parts});
        continue;
      }
      if (message.toolCalls.isNotEmpty) {
        out.add({
          'role': 'model',
          'parts': <Object?>[
            if (message.content.isNotEmpty) {'text': message.content},
            for (final call in message.toolCalls)
              {
                'functionCall': {'name': call.name, 'args': call.arguments},
                // Echoed verbatim: Gemini 3.x rejects a continuation whose
                // functionCall part has lost its signature.
                if (call.providerSignature != null)
                  'thoughtSignature': call.providerSignature,
              },
          ],
        });
        i++;
        continue;
      }
      out.add({
        'role': message.role == AiRole.user ? 'user' : 'model',
        'parts': [
          {'text': message.content},
        ],
      });
      i++;
    }
    return out;
  }

  /// The id [AiToolCall.id] carries for a Gemini call.
  ///
  /// Gemini's `functionCall` has no id field, and the rest of this package —
  /// and every caller routing results back — is built around one. The id is
  /// derived from the call's position in the turn and the function name, so it
  /// is stable for a given response and carries enough to reconstruct the name
  /// when the history is not available to look it up in.
  static String syntheticToolCallId(int index, String name) =>
      'call_${index}_$name';

  static final _syntheticId = RegExp(r'^call_\d+_(.+)$');

  /// Recovers the function name a result is answering: first from the calls in
  /// the history, then from the shape [syntheticToolCallId] minted. An id from
  /// somewhere else entirely is passed through as the name — wrong, but
  /// visibly wrong in the provider's error rather than silently empty.
  static String _toolNameFor(String toolCallId, List<AiMessage> messages) {
    for (final message in messages) {
      for (final call in message.toolCalls) {
        if (call.id == toolCallId) return call.name;
      }
    }
    return _syntheticId.firstMatch(toolCallId)?.group(1) ?? toolCallId;
  }

  /// Appends every `functionCall` part in a response — or a stream chunk — to
  /// [into], minting ids from the running length so two calls in one turn stay
  /// distinguishable.
  @visibleForTesting
  static void collectToolCalls(
    Map<String, Object?> json,
    List<AiToolCall> into,
  ) {
    final candidates = json['candidates'] as List<Object?>? ?? const [];
    if (candidates.isEmpty) return;
    final first = candidates.first;
    if (first is! Map<String, Object?>) return;
    final content = first['content'] as Map<String, Object?>?;
    final parts = content?['parts'] as List<Object?>? ?? const [];
    for (final part in parts) {
      if (part is! Map<String, Object?>) continue;
      final call = part['functionCall'] as Map<String, Object?>?;
      if (call == null) continue;
      final name = call['name'] as String? ?? '';
      into.add(
        AiToolCall(
          id: syntheticToolCallId(into.length, name),
          name: name,
          arguments: decodeToolArguments(call['args']),
          // Sits beside `functionCall` on the same part, not inside it.
          providerSignature: part['thoughtSignature'] as String?,
        ),
      );
    }
  }
}
