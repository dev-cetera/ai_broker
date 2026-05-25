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

import 'dart:io';

import 'package:ai_broker/ai_broker.dart';

// Set ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY in the env,
// pick one with the first CLI arg, then this example does:
//
//   - listModels (sanity check that the key works)
//   - a single-shot complete()
//   - a streamed chat() that prints token-by-token to stdout
//
// Run:
//   ANTHROPIC_API_KEY=... dart run example/example.dart anthropic
//   OPENAI_API_KEY=... dart run example/example.dart openai gpt-4o-mini
//   GEMINI_API_KEY=... dart run example/example.dart gemini gemini-2.5-flash

Future<void> main(List<String> args) async {
  AiBrokerRegistry.instance
    ..register(OpenAiBroker())
    ..register(AnthropicBroker())
    ..register(GeminiBroker());

  final brokerId = args.isNotEmpty ? args.first : 'anthropic';
  final broker = AiBrokerRegistry.instance.lookup(brokerId);
  if (broker == null) {
    stderr.writeln('Unknown broker "$brokerId". '
        'Known: ${AiBrokerRegistry.instance.all.map((b) => b.id).join(', ')}');
    exit(1);
  }

  final keys = EnvKeyResolver();
  final apiKey = await keys.require(broker.id);

  stdout.writeln('Listing models for ${broker.label}…');
  final models = await broker.listModels(apiKey);
  if (models.isEmpty) {
    stderr.writeln('No models returned. Is the API key valid?');
    exit(1);
  }
  final model = args.length >= 2 ? args[1] : models.first;
  stdout.writeln('Using model: $model (of ${models.length} available)\n');

  stdout.writeln('--- complete() ---');
  final answer = await broker.complete(
    apiKey: apiKey,
    model: model,
    system: 'You answer in exactly one sentence.',
    user: 'Why is the sky blue?',
  );
  stdout.writeln(answer);

  stdout.writeln('\n--- stream() ---');
  final stream = broker.stream(
    apiKey: apiKey,
    model: model,
    request: const ChatRequest(
      system: 'You write short, vivid prose.',
      messages: [
        AiMessage.user('Describe a sunset over the ocean in three sentences.'),
      ],
      maxTokens: 200,
    ),
  );
  await for (final chunk in stream) {
    stdout.write(chunk);
  }
  stdout.writeln();
}
