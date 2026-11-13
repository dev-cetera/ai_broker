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
import '../core/_abort.dart';

/// Any provider that speaks the OpenAI Chat Completions API
/// (`POST {baseUrl}/chat/completions`, `GET {baseUrl}/models`, bearer-token
/// auth): DeepSeek, OpenRouter, Mistral, Groq, xAI, Together, Fireworks, or a
/// local server such as Ollama, LM Studio or vLLM. Implements [ChatBroker]
/// and [KeyCheckBroker].
///
/// ```dart
/// final groq = OpenAiCompatibleBroker(
///   id: 'groq',
///   label: 'Groq',
///   baseUrl: 'https://api.groq.com/openai/v1',
/// );
/// ```
///
/// [OpenAiBroker] and [DeepSeekBroker] are presets built on this class.
/// Providers differ in small ways the constructor exposes: the field that
/// carries the token ceiling ([maxTokensField]), whether `json_schema`
/// structured output is accepted ([supportsJsonSchema]), and whether a
/// stream may ask for usage ([streamUsage]).
class OpenAiCompatibleBroker extends ChatBroker implements KeyCheckBroker {
  /// Chat requests are not quick calls. A reasoning model doing a structured
  /// judge over a knowledge bundle measured 21.5s on a synthetic input and
  /// more on a real one, so the old 30s cut them off mid-thought.
  static const defaultTimeout = Duration(seconds: 120);

  @override
  final String id;

  @override
  final String label;

  /// Everything before `/chat/completions`, with no trailing slash, e.g.
  /// `https://api.openai.com/v1`.
  final String baseUrl;

  /// The body field for [ChatRequest.maxTokens]: `max_completion_tokens`
  /// (OpenAI's current name; `max_tokens` is deprecated there and rejected
  /// by o-series models) or `max_tokens` (most other providers).
  final String maxTokensField;

  /// Whether the provider accepts `response_format: {type: 'json_schema'}`.
  /// When false, [ChatRequest.jsonSchema] is sent as JSON mode plus the
  /// schema in the system prompt.
  final bool supportsJsonSchema;

  /// Whether to send `stream_options: {include_usage: true}` on streams, so
  /// the streamed completion carries token counts.
  final bool streamUsage;

  /// Request timeout for every call.
  final Duration timeout;

  final bool Function(String modelId)? _modelFilter;
  final Map<String, String> _extraHeaders;

  /// The HTTP client every request goes through.
  @protected
  final Client httpClient;

  OpenAiCompatibleBroker({
    required this.id,
    required this.label,
    required String baseUrl,
    Client? client,
    bool Function(String modelId)? modelFilter,
    this.maxTokensField = 'max_tokens',
    this.supportsJsonSchema = true,
    this.streamUsage = true,
    this.timeout = defaultTimeout,
    Map<String, String> extraHeaders = const {},
  })  : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        httpClient = client ?? Client(),
        _modelFilter = modelFilter,
        _extraHeaders = extraHeaders;

  @override
  String get emptyReplyPhrase => 'empty content';

  /// Whether [listModels] keeps [modelId]. Every model by default; presets
  /// filter out embeddings, audio and image models.
  @protected
  bool isChatModel(String modelId) => _modelFilter?.call(modelId) ?? true;

  /// Bearer auth plus any extra headers given to the constructor (OpenRouter's
  /// `HTTP-Referer`, for example).
  @protected
  Map<String, String> authHeaders(String apiKey) => {
        'Authorization': 'Bearer $apiKey',
        ..._extraHeaders,
      };

  @override
  Future<List<String>> listModels(String apiKey) async {
    if (apiKey.isEmpty) return const [];
    final res = await httpClient
        .get(Uri.parse('$baseUrl/models'), headers: authHeaders(apiKey))
        .timeout(timeout);
    if (res.statusCode >= 400) return const [];
    final body = jsonDecode(res.body) as Map<String, Object?>;
    final data = body['data'] as List<Object?>? ?? const [];
    final ids = <String>[];
    for (final m in data) {
      if (m is! Map<String, Object?>) continue;
      final modelId = m['id'] as String?;
      if (modelId == null) continue;
      if (!isChatModel(modelId)) continue;
      ids.add(modelId);
    }
    ids.sort();
    return ids;
  }

  @override
  Future<AiKeyCheck> checkKey(String apiKey) => checkKeyByRequest(
        apiKey,
        providerLabel: label,
        send: () => httpClient
            .get(Uri.parse('$baseUrl/models'), headers: authHeaders(apiKey))
            .timeout(timeout),
      );

  @override
  Future<AiCompletion> chatWithMeta({
    required String apiKey,
    required String model,
    required ChatRequest request,
    Future<void>? abortTrigger,
  }) async {
    final body = jsonEncode(buildPayload(model, request, stream: false));
    final res = await retryRequest(
      send: () => postWithAbort(
        httpClient,
        Uri.parse('$baseUrl/chat/completions'),
        headers: {
          ...authHeaders(apiKey),
          'Content-Type': 'application/json',
        },
        body: body,
        abortTrigger: abortTrigger,
      ).timeout(timeout),
      providerLabel: label,
      isHardFailure: (r) =>
          r.statusCode == 429 && r.body.toLowerCase().contains('quota'),
      abortTrigger: abortTrigger,
    );
    final json = jsonDecode(res.body) as Map<String, Object?>;
    final choices = json['choices'] as List<Object?>?;
    if (choices == null || choices.isEmpty) {
      throw AiBrokerException('$label returned no choices.');
    }
    final first = choices.first as Map<String, Object?>;
    final message = first['message'] as Map<String, Object?>?;
    final content = message?['content'] as String? ?? '';
    final usage = json['usage'] as Map<String, Object?>? ?? const {};
    int? count(String key) => (usage[key] as num?)?.toInt();
    final rawFinishReason = first['finish_reason'] as String?;
    final details = usage['completion_tokens_details'] as Map<String, Object?>?;
    final cached =
        (usage['prompt_tokens_details'] as Map<String, Object?>?) ?? const {};
    return AiCompletion(
      text: content.trim(),
      model: json['model'] as String? ?? model,
      rawFinishReason: rawFinishReason,
      finishReason: _finishReasonOf(rawFinishReason),
      inputTokens: count('prompt_tokens'),
      outputTokens: count('completion_tokens'),
      thinkingTokens: (details?['reasoning_tokens'] as num?)?.toInt(),
      cacheReadInputTokens: (cached['cached_tokens'] as num?)?.toInt() ?? 0,
      toolCalls: _parseToolCalls(message?['tool_calls']),
    );
  }

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
    Future<void>? abortTrigger,
  }) =>
      streamWithMeta(
        apiKey: apiKey,
        model: model,
        request: request,
        abortTrigger: abortTrigger,
      ).deltas;

  @override
  StreamedCompletion streamWithMeta({
    required String apiKey,
    required String model,
    required ChatRequest request,
    Future<void>? abortTrigger,
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
        abortTrigger: abortTrigger,
      ),
      completion: completer.future,
    );
  }

  /// The SSE read loop behind [stream] and [streamWithMeta].
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
    Future<void>? abortTrigger,
  }) async* {
    final buf = StringBuffer();
    var servingModel = model;
    String? rawFinishReason;
    int? inputTokens;
    int? outputTokens;
    int? thinkingTokens;
    var cachedTokens = 0;
    final partialTools = <int, _PartialToolCall>{};

    try {
      final body = jsonEncode(buildPayload(model, request, stream: true));
      final byteStream = await openSsePost(
        uri: Uri.parse('$baseUrl/chat/completions'),
        headers: {
          ...authHeaders(apiKey),
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
        },
        body: body,
        providerLabel: label,
        client: httpClient,
        abortTrigger: abortTrigger,
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
          final completion =
              usage['completion_tokens_details'] as Map<String, Object?>?;
          thinkingTokens = (completion?['reasoning_tokens'] as num?)?.toInt() ??
              thinkingTokens;
        }
        final choices = json['choices'] as List<Object?>? ?? const [];
        if (choices.isEmpty) return;
        final choice = choices.first as Map<String, Object?>;
        final finish = choice['finish_reason'] as String?;
        if (finish != null) rawFinishReason = finish;
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
            rawFinishReason: rawFinishReason,
            finishReason: _finishReasonOf(rawFinishReason),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            thinkingTokens: thinkingTokens,
            cacheReadInputTokens: cachedTokens,
            toolCalls: _drainPartials(partialTools),
          ),
        );
      }
    }
  }

  /// Maps the OpenAI `finish_reason` vocabulary onto [AiFinishReason].
  /// `tool_calls` is how a tool-use turn announces itself. Returns `null`
  /// for a value this package does not know; the raw string is still
  /// carried on [AiCompletion.rawFinishReason].
  static AiFinishReason? _finishReasonOf(String? raw) => switch (raw) {
        'stop' => AiFinishReason.stop,
        'length' => AiFinishReason.maxTokens,
        'content_filter' => AiFinishReason.safety,
        'tool_calls' || 'function_call' => AiFinishReason.toolUse,
        // Unmapped on purpose: anything newer than this package.
        _ => null,
      };

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

  /// Build the request body. Shared by [chatWithMeta] and [stream], so
  /// structured output behaves identically on both.
  ///
  /// [ChatRequest.jsonSchema] becomes `response_format`. Where the provider
  /// supports it ([supportsJsonSchema]) that is `json_schema` with
  /// `strict: true`, which makes the constraint binding rather than
  /// advisory; it is also the fussiest mode on the wire: every object must
  /// carry `additionalProperties: false` and must name every property in
  /// `required`. [toOpenAiStrictSchema] adds both where the caller left them
  /// out — the exact opposite of what Gemini needs from the same schema.
  /// Providers with only JSON mode (DeepSeek) get `json_object`, and the
  /// schema is appended to the system prompt, since JSON mode guarantees
  /// valid JSON but not its shape.
  ///
  /// [ChatRequest.tools] becomes `tools: [{type: 'function', function: {…}}]`
  /// — the extra `function` wrapper is OpenAI's alone. The schema goes through
  /// verbatim: tool arguments are not strict-mode structured output, so the
  /// rewriting [toOpenAiStrictSchema] does would only narrow what the model
  /// may send.
  ///
  /// [ChatRequest.temperature] is sent only when set, and
  /// [ChatRequest.effort] becomes `reasoning_effort`. The token ceiling goes
  /// in [maxTokensField].
  @visibleForTesting
  Map<String, Object?> buildPayload(
    String model,
    ChatRequest req, {
    required bool stream,
  }) {
    final schema = req.jsonSchema;
    final tools = req.tools;
    final hasTools = tools != null && tools.isNotEmpty;
    final jsonMode = schema != null && !supportsJsonSchema;
    final system =
        jsonMode ? _withSchemaInstruction(req.system, schema) : req.system;
    return {
      'model': model,
      'messages': [
        if (system.isNotEmpty) {'role': 'system', 'content': system},
        ..._renderMessages(req.messages),
      ],
      if (req.temperature != null) 'temperature': req.temperature,
      maxTokensField: req.maxTokens,
      if (req.effort != null) 'reasoning_effort': req.effort!.wire,
      if (schema != null && supportsJsonSchema)
        'response_format': {
          'type': 'json_schema',
          'json_schema': {
            'name': 'response',
            'strict': true,
            'schema': toOpenAiStrictSchema(schema),
          },
        },
      if (jsonMode) 'response_format': {'type': 'json_object'},
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
      // Without this the stream carries no token counts at all.
      if (stream && streamUsage) 'stream_options': {'include_usage': true},
    };
  }

  /// JSON mode needs the word "json" and the expected shape in the prompt.
  static String _withSchemaInstruction(
    String system,
    Map<String, Object?> schema,
  ) {
    final instruction = 'Reply with a single JSON object only, matching this '
        'JSON Schema:\n${jsonEncode(schema)}';
    return system.isEmpty ? instruction : '$system\n\n$instruction';
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
}

/// One streamed `tool_calls` slot being assembled. Every field is optional on
/// any given chunk — the id and name usually land on the first one, the
/// argument text on the ones after — so each is filled in as it shows up.
class _PartialToolCall {
  String id = '';
  String name = '';
  final StringBuffer json = StringBuffer();
}
