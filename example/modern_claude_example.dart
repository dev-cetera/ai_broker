// Calling a current-generation Claude model (Opus 5 / Sonnet 5) correctly.
//
// The four things that changed and now 400 if you get them wrong:
//   * no `temperature` — use `effort` instead
//   * no assistant prefill — use `jsonSchema` to force JSON
//   * `cacheSystem: true` to stop paying full price for a repeated prefix
//   * a refusal is an HTTP 200 with `stop_reason: refusal`, not an error
//
// Run against the real API with ANTHROPIC_API_KEY set, or against a local
// double by passing `baseUrl`.

import 'package:ai_broker/ai_broker.dart';

Future<void> main() async {
  final broker = AnthropicBroker(baseUrl: 'http://127.0.0.1:8792/v1');

  // 1. A modern-model chat turn: no temperature, effort set, system cached.
  final res = await broker.chatDetailed(
    apiKey: 'test-key',
    model: 'claude-opus-5',
    request: ChatRequest.single(
      system: '# Acme Plumbing\nAnswer from the knowledge base.',
      user: 'what are your hours?',
      effort: AiEffort.low,
      maxTokens: 512,
      cacheSystem: true,
    ),
  );
  print(
    'CHAT ok stop=${res.stopReason.wire} '
    'in=${res.inputTokens} out=${res.outputTokens}',
  );
  print('CHAT text="${res.text}"');

  // 2. Structured output for a judge call.
  final judge = await broker.chatDetailed(
    apiKey: 'test-key',
    model: 'claude-opus-5',
    request: ChatRequest.single(
      system: 'You are a judge.',
      user: '[{"index":1},{"index":2},{"index":3}]',
      effort: AiEffort.high,
      maxTokens: 16000,
      jsonSchema: const {
        'type': 'object',
        'additionalProperties': false,
        'required': ['scores'],
        'properties': {
          'scores': {
            'type': 'array',
            'items': {'type': 'object'},
          },
        },
      },
    ),
  );
  print('JUDGE raw=${judge.text.substring(0, 60)}...');

  // 3. Streaming.
  final buf = StringBuffer();
  await for (final delta in broker.stream(
    apiKey: 'test-key',
    model: 'claude-opus-5',
    request: ChatRequest.single(
      system: '# Acme Plumbing',
      user: 'hi',
      effort: AiEffort.low,
    ),
  )) {
    buf.write(delta);
  }
  print('STREAM text="$buf"');

  // 4. The old behaviour must still be rejected by the server.
  try {
    await broker.chat(
      apiKey: 'test-key',
      model: 'claude-opus-5',
      request: const ChatRequest(system: 's', messages: [], temperature: 0.3),
    );
    print('TEMPERATURE: NOT REJECTED  <-- would have been a prod 400');
  } on AiBrokerException catch (e) {
    print('TEMPERATURE correctly rejected upstream: ${e.statusCode}');
  }
}
