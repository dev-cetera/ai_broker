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
            // A tool-use turn carries no text on purpose — the answer is the
            // call. `chat` has no way to return one, so say which method does
            // rather than reporting a bare empty reply.
            : toolNoTextMessage('Anthropic', 'empty text', result.toolCalls),
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
    // One turn can hold several `tool_use` blocks interleaved with text —
    // "let me check both cities" followed by two calls. Keep them all, in
    // order; the caller has to answer every one of them.
    final toolCalls = <AiToolCall>[];
    for (final block in content) {
      if (block is! Map<String, Object?>) continue;
      switch (block['type']) {
        case 'text':
          buf.write(block['text'] as String? ?? '');
        case 'tool_use':
          toolCalls.add(
            AiToolCall(
              id: block['id'] as String? ?? '',
              name: block['name'] as String? ?? '',
              arguments: decodeToolArguments(block['input']),
            ),
          );
      }
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

  /// The SSE read loop behind [stream] and [streamDetailed]. Yields text as
  /// it arrives — nothing is held back — and completes [completer] from the
  /// bookkeeping events once the message ends.
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
    var cacheReadInputTokens = 0;
    var cacheCreationInputTokens = 0;
    // Tool calls arrive as a block per index: `content_block_start` names the
    // tool, then `input_json_delta` events dribble the arguments in as JSON
    // fragments that are only parseable once concatenated. Keyed by block
    // index because two calls interleave on the wire.
    final partialTools = <int, _PartialToolCall>{};

    // Usage arrives twice and in pieces: `message_start` knows the input and
    // cache counts, `message_delta` knows the final output count. Take each
    // key only when the event actually carries it, so the later event can't
    // zero out what the earlier one reported.
    void readUsage(Object? raw) {
      if (raw is! Map<String, Object?>) return;
      int? at(String key) => (raw[key] as num?)?.toInt();
      inputTokens = at('input_tokens') ?? inputTokens;
      outputTokens = at('output_tokens') ?? outputTokens;
      cacheReadInputTokens =
          at('cache_read_input_tokens') ?? cacheReadInputTokens;
      cacheCreationInputTokens =
          at('cache_creation_input_tokens') ?? cacheCreationInputTokens;
    }

    // Anthropic stream events:
    //  - message_start       → { message: { model, usage } }
    //  - content_block_start → { index, content_block: { type: 'tool_use',
    //                            id, name } }
    //  - content_block_delta → { index, delta: { type: 'text_delta', text } }
    //                        | { index, delta: { type: 'input_json_delta',
    //                            partial_json } }
    //  - message_delta       → { delta: { stop_reason }, usage }
    //  - message_stop        → end of stream
    // Other events (ping, content_block_stop, etc.) are ignored.
    Iterable<String> consume(SseEvent event) sync* {
      final name = event.event;
      if (event.data.isEmpty) return;
      // Decode only what we act on. An unrecognised event — a gateway's own
      // keep-alive, say — may not carry JSON at all.
      if (name != 'message_start' &&
          name != 'content_block_start' &&
          name != 'content_block_delta' &&
          name != 'message_delta') {
        return;
      }
      final json = jsonDecode(event.data) as Map<String, Object?>;
      if (name == 'message_start') {
        final message = json['message'] as Map<String, Object?>?;
        if (message == null) return;
        // The serving model can differ from the one that was requested.
        servingModel = message['model'] as String? ?? servingModel;
        readUsage(message['usage']);
      } else if (name == 'content_block_start') {
        final block = json['content_block'] as Map<String, Object?>?;
        final index = (json['index'] as num?)?.toInt();
        if (block == null || index == null) return;
        if (block['type'] != 'tool_use') return;
        partialTools[index] = _PartialToolCall(
          id: block['id'] as String? ?? '',
          name: block['name'] as String? ?? '',
        );
      } else if (name == 'content_block_delta') {
        final delta = json['delta'] as Map<String, Object?>?;
        if (delta == null) return;
        if (delta['type'] == 'input_json_delta') {
          final index = (json['index'] as num?)?.toInt();
          if (index == null) return;
          // No matching `content_block_start` means this is a block we never
          // opened — a shape we don't model. Dropping it beats inventing a
          // nameless call.
          final partial = partialTools[index];
          if (partial == null) return;
          partial.json.write(delta['partial_json'] as String? ?? '');
          return;
        }
        if (delta['type'] != 'text_delta') return;
        final text = delta['text'] as String?;
        if (text == null || text.isEmpty) return;
        buf.write(text);
        yield text;
      } else if (name == 'message_delta') {
        // The one event that says *why* the turn ended — including
        // `refusal`, which otherwise looks exactly like a short reply.
        final delta = json['delta'] as Map<String, Object?>?;
        if (delta != null) {
          stopReason = AiStopReason.fromWire(delta['stop_reason'] as String?);
        }
        readUsage(json['usage']);
      }
    }

    try {
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
      // `yield*` rather than `await for`, so a consumer that cancels
      // mid-reply is acknowledged at once and the `finally` below still
      // runs. Stream errors bypass the enclosing catch as a result, hence
      // the `handleError` hop.
      yield* decodeSseStream(byteStream)
          .takeWhile((event) => event.event != 'message_stop')
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
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            // Assembled here rather than at `content_block_stop`, so a stream
            // that was cancelled or cut short still reports the calls it saw —
            // with whatever arguments parsed, which may be none.
            toolCalls: _drainPartials(partialTools),
          ),
        );
      }
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
  ///
  /// [ChatRequest.tools] becomes a flat `tools` array of
  /// `{name, description, input_schema}` — the schema goes verbatim, the same
  /// way `output_config.format` does. `tool_choice` is an object here, not a
  /// string, and [AiToolChoice.required] is spelled `any`.
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
    final tools = req.tools;
    final hasTools = tools != null && tools.isNotEmpty;
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
      'messages': _renderMessages(req.messages),
      if (hasTools)
        'tools': [
          for (final tool in tools)
            {
              'name': tool.name,
              'description': tool.description,
              'input_schema': tool.inputSchema,
            },
        ],
      if (hasTools && req.toolChoice != null)
        'tool_choice': {'type': _toolChoiceType(req.toolChoice!)},
      if (outputConfig.isNotEmpty) 'output_config': outputConfig,
      if (stream) 'stream': true,
    };
  }

  /// Anthropic's word for "you must call something" is `any`, not `required`.
  static String _toolChoiceType(AiToolChoice choice) =>
      choice == AiToolChoice.required ? 'any' : choice.wire;

  /// Renders the turn history into Anthropic's message array.
  ///
  /// Plain turns keep the string-content shorthand they have always used, so
  /// a request without tools is byte-for-byte what earlier versions sent.
  /// The two tool shapes need block content:
  ///
  ///  * an assistant turn that asked for tools becomes an optional `text`
  ///    block followed by one `tool_use` block per call;
  ///  * **every consecutive tool result collapses into one user message.**
  ///    This is the rule that bites: a model that asked for three tools in one
  ///    turn expects all three results in a single following message, and
  ///    splitting them across three messages is a 400.
  static List<Map<String, Object?>> _renderMessages(List<AiMessage> messages) {
    final out = <Map<String, Object?>>[];
    var i = 0;
    while (i < messages.length) {
      final message = messages[i];
      if (message.isToolResult) {
        final blocks = <Object?>[];
        while (i < messages.length && messages[i].isToolResult) {
          final result = messages[i];
          blocks.add({
            'type': 'tool_result',
            'tool_use_id': result.toolCallId,
            'content': result.content,
            // Absent means false; only send the flag when it says something.
            if (result.isError) 'is_error': true,
          });
          i++;
        }
        out.add({'role': 'user', 'content': blocks});
        continue;
      }
      if (message.toolCalls.isNotEmpty) {
        out.add({
          'role': message.roleName,
          'content': <Object?>[
            if (message.content.isNotEmpty)
              {'type': 'text', 'text': message.content},
            for (final call in message.toolCalls)
              {
                'type': 'tool_use',
                'id': call.id,
                'name': call.name,
                'input': call.arguments,
              },
          ],
        });
        i++;
        continue;
      }
      out.add({'role': message.roleName, 'content': message.content});
      i++;
    }
    return out;
  }

  /// Turns the accumulated `input_json_delta` fragments into calls, in block
  /// order. A buffer that never became valid JSON yields an empty argument
  /// map rather than dropping the call — see [decodeToolArguments].
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
}

/// A `tool_use` block being assembled from stream events: the id and name land
/// whole on `content_block_start`, the arguments arrive as JSON fragments that
/// only parse once concatenated.
class _PartialToolCall {
  _PartialToolCall({required this.id, required this.name});

  final String id;
  final String name;
  final StringBuffer json = StringBuffer();
}
