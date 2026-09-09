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

  /// Chat requests are not quick calls. A reasoning model doing a structured
  /// judge over a knowledge bundle measured 21.5s here on a synthetic input and
  /// more on a real one, so the old 30s cut them off mid-thought and surfaced
  /// as a bare TimeoutException far from the cause. Matches the Anthropic
  /// broker, which was raised for exactly this reason in 0.4.0.
  static const _timeout = Duration(seconds: 120);
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
    final result = await chatDetailed(
      apiKey: apiKey,
      model: model,
      request: request,
    );
    if (result.text.isEmpty) {
      // A tool-use turn sends `content: null` on purpose — the answer is the
      // call. `chat` has no way to return one, so say which method does.
      throw AiBrokerException(
        toolNoTextMessage('OpenAI', 'empty content', result.toolCalls),
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
    final content = message?['content'] as String? ?? '';
    final usage = json['usage'] as Map<String, Object?>? ?? const {};
    int count(String key) => (usage[key] as num?)?.toInt() ?? 0;
    final cached =
        (usage['prompt_tokens_details'] as Map<String, Object?>?) ?? const {};
    return AiCompletion(
      text: content.trim(),
      model: json['model'] as String? ?? model,
      stopReason: _stopReasonFrom(first['finish_reason'] as String?),
      inputTokens: count('prompt_tokens'),
      outputTokens: count('completion_tokens'),
      cacheReadInputTokens: (cached['cached_tokens'] as num?)?.toInt() ?? 0,
      toolCalls: _parseToolCalls(message?['tool_calls']),
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

  /// The SSE read loop behind [stream] and [streamDetailed].
  ///
  /// OpenAI streams a tool call the same way it streams text: in pieces. The
  /// first chunk for a slot carries the `id` and `function.name`, every chunk
  /// after it appends to `function.arguments` — a JSON **string** built one
  /// fragment at a time, which cannot be parsed until the stream ends. Slots
  /// are keyed by `index`, so two calls can interleave.
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
    final partialTools = <int, _PartialToolCall>{};

    try {
      final body = jsonEncode(buildPayload(model, request, stream: true));
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

      Iterable<String> consume(SseEvent event) sync* {
        final data = event.data;
        if (data.isEmpty || data == '[DONE]') return;
        final json = jsonDecode(data) as Map<String, Object?>;
        servingModel = json['model'] as String? ?? servingModel;
        final usage = json['usage'] as Map<String, Object?>?;
        if (usage != null) {
          int? at(String key) => (usage[key] as num?)?.toInt();
          inputTokens = at('prompt_tokens') ?? inputTokens;
          outputTokens = at('completion_tokens') ?? outputTokens;
          final details =
              usage['prompt_tokens_details'] as Map<String, Object?>?;
          cachedTokens =
              (details?['cached_tokens'] as num?)?.toInt() ?? cachedTokens;
        }
        final choices = json['choices'] as List<Object?>? ?? const [];
        if (choices.isEmpty) return;
        final choice = choices.first as Map<String, Object?>;
        final finish = choice['finish_reason'] as String?;
        if (finish != null) stopReason = _stopReasonFrom(finish);
        final delta = choice['delta'] as Map<String, Object?>?;
        if (delta == null) return;
        for (final raw in delta['tool_calls'] as List<Object?>? ?? const []) {
          if (raw is! Map<String, Object?>) continue;
          // `index` is what ties fragments to a slot. Without it there is
          // nothing to append to, so treat the entry as the first slot.
          final index = (raw['index'] as num?)?.toInt() ?? 0;
          final fn = raw['function'] as Map<String, Object?>?;
          final slot = partialTools.putIfAbsent(index, _PartialToolCall.new);
          slot.id = raw['id'] as String? ?? slot.id;
          slot.name = fn?['name'] as String? ?? slot.name;
          slot.json.write(fn?['arguments'] as String? ?? '');
        }
        final content = delta['content'] as String?;
        if (content == null || content.isEmpty) return;
        buf.write(content);
        yield content;
      }

      // `yield*` rather than `await for`, so a consumer that cancels
      // mid-reply is acknowledged at once and the `finally` below still
      // runs. Stream errors bypass the enclosing catch as a result, hence
      // the `handleError` hop.
      yield* decodeSseStream(byteStream)
          .takeWhile((event) => event.data != '[DONE]')
          .expand(consume)
          .handleError((Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
        Error.throwWithStackTrace(e, st);
      });
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
            toolCalls: _drainPartials(partialTools),
          ),
        );
      }
    }
  }

  /// OpenAI has its own vocabulary for why generation stopped. `tool_calls`
  /// is the one that matters here: it is how a tool-use turn announces itself,
  /// and it maps onto the shared [AiStopReason.toolUse].
  static AiStopReason _stopReasonFrom(String? finishReason) {
    switch (finishReason) {
      case 'stop':
        return AiStopReason.endTurn;
      case 'length':
        return AiStopReason.maxTokens;
      case 'tool_calls':
      case 'function_call':
        return AiStopReason.toolUse;
      case 'content_filter':
        return AiStopReason.refusal;
      default:
        return AiStopReason.unknown;
    }
  }

  /// Reads the non-streaming `tool_calls` array.
  ///
  /// `function.arguments` is a JSON **string**, not an object — the single
  /// most-missed detail in this API. [decodeToolArguments] parses it; nothing
  /// downstream ever sees the raw text, so nothing downstream is tempted to
  /// match on it.
  static List<AiToolCall> _parseToolCalls(Object? raw) {
    if (raw is! List<Object?> || raw.isEmpty) return const [];
    final out = <AiToolCall>[];
    for (final entry in raw) {
      if (entry is! Map<String, Object?>) continue;
      final fn = entry['function'] as Map<String, Object?>?;
      if (fn == null) continue;
      out.add(
        AiToolCall(
          id: entry['id'] as String? ?? '',
          name: fn['name'] as String? ?? '',
          arguments: decodeToolArguments(fn['arguments']),
        ),
      );
    }
    return out;
  }

  /// Turns the accumulated argument fragments into calls, in slot order. A
  /// buffer that never became valid JSON — a stream cut mid-object — yields an
  /// empty argument map rather than dropping the call.
  static List<AiToolCall> _drainPartials(Map<int, _PartialToolCall> partials) {
    if (partials.isEmpty) return const [];
    final indices = partials.keys.toList()..sort();
    return [
      for (final index in indices)
        AiToolCall(
          id: partials[index]!.id,
          name: partials[index]!.name,
          arguments: decodeToolArguments(partials[index]!.json.toString()),
        ),
    ];
  }

  /// Build the request body. Shared by [chat] and [stream], so structured
  /// output behaves identically on both.
  ///
  /// [ChatRequest.jsonSchema] becomes `response_format`. `strict: true` is
  /// what makes the constraint binding rather than advisory, and it is also
  /// the fussiest mode on the wire: every object must carry
  /// `additionalProperties: false` and must name every property in
  /// `required`. [toOpenAiStrictSchema] adds both where the caller left them
  /// out — the exact opposite of what Gemini needs from the same schema.
  ///
  /// [ChatRequest.tools] becomes `tools: [{type: 'function', function: {…}}]`
  /// — the extra `function` wrapper is OpenAI's alone. The schema goes through
  /// verbatim: tool arguments are not strict-mode structured output, so the
  /// rewriting [toOpenAiStrictSchema] does would only narrow what the model
  /// may send.
  @visibleForTesting
  Map<String, Object?> buildPayload(
    String model,
    ChatRequest req, {
    required bool stream,
  }) {
    final schema = req.jsonSchema;
    final tools = req.tools;
    final hasTools = tools != null && tools.isNotEmpty;
    return {
      'model': model,
      'messages': [
        if (req.system.isNotEmpty) {'role': 'system', 'content': req.system},
        ..._renderMessages(req.messages),
      ],
      'temperature': req.temperature,
      'max_tokens': req.maxTokens,
      if (schema != null)
        'response_format': {
          'type': 'json_schema',
          'json_schema': {
            'name': 'response',
            'strict': true,
            'schema': toOpenAiStrictSchema(schema),
          },
        },
      if (hasTools)
        'tools': [
          for (final tool in tools)
            {
              'type': 'function',
              'function': {
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.inputSchema,
              },
            },
        ],
      // A bare string here, where Anthropic wants an object. `required` is
      // spelled the same way this package spells it, for once.
      if (hasTools && req.toolChoice != null)
        'tool_choice': req.toolChoice!.wire,
      if (stream) 'stream': true,
    };
  }

  /// Renders the turn history into OpenAI's message array.
  ///
  /// Plain turns are unchanged. The two tool shapes are both messages of their
  /// own — unlike Anthropic, nothing is coalesced: a turn that asked for three
  /// tools is answered by three separate `role: 'tool'` messages, one per
  /// `tool_call_id`.
  static List<Map<String, Object?>> _renderMessages(List<AiMessage> messages) {
    final out = <Map<String, Object?>>[];
    for (final message in messages) {
      if (message.isToolResult) {
        out.add({
          'role': 'tool',
          'tool_call_id': message.toolCallId,
          'content': message.content,
        });
        continue;
      }
      if (message.toolCalls.isNotEmpty) {
        out.add({
          'role': message.roleName,
          // Null, not '' — an empty string is a different thing to the API,
          // and a tool-use turn usually has no text at all.
          'content': message.content.isEmpty ? null : message.content,
          'tool_calls': [
            for (final call in message.toolCalls)
              {
                'id': call.id,
                'type': 'function',
                'function': {
                  'name': call.name,
                  // Back to a string on the way out, the same way it arrived.
                  'arguments': jsonEncode(call.arguments),
                },
              },
          ],
        });
        continue;
      }
      out.add({'role': message.roleName, 'content': message.content});
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

/// One streamed `tool_calls` slot being assembled. Every field is optional on
/// any given chunk — the id and name usually land on the first one, the
/// argument text on the ones after — so each is filled in as it shows up.
class _PartialToolCall {
  String id = '';
  String name = '';
  final StringBuffer json = StringBuffer();
}
