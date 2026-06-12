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

import 'package:args/command_runner.dart';

import '/_common.dart';

/// `aib ask "<question>"` — one-shot RAG:
///
///   1. retrieve top-K snippets from a collection (cosine over embeddings),
///   2. feed them as the system prompt to a chat broker,
///   3. stream the answer to stdout.
///
/// The embed broker is always the collection's pinned one (whatever
/// `ingest` used). The chat broker is configurable independently — by
/// default Anthropic, because Claude is best at "answer only from these
/// excerpts" grounding.
class AskCommand extends Command<int> {
  final AiBroker Function(String) _brokerFactory;
  final KeyResolver? _keyResolverOverride;

  AskCommand({
    AiBroker Function(String)? brokerFactory,
    KeyResolver? keyResolver,
  })  : _brokerFactory = brokerFactory ?? brokerForId,
        _keyResolverOverride = keyResolver {
    addKeyArgs(argParser);
    argParser
      ..addOption(
        'collection',
        abbr: 'c',
        defaultsTo: 'default',
        help: 'Collection to retrieve from.',
      )
      ..addOption(
        'db',
        help: 'SQLite path (default: \$AIB_DB or ~/.ai_broker/corpus.db).',
      )
      ..addOption(
        'top-k',
        abbr: 'k',
        defaultsTo: '8',
        help: 'Number of snippets to feed as context.',
      )
      ..addOption(
        'broker',
        defaultsTo: 'anthropic',
        allowed: ['anthropic', 'openai', 'gemini'],
        help: 'Chat broker (independent of the collection\'s embed broker).',
      )
      ..addOption(
        'model',
        defaultsTo: 'claude-sonnet-4-6',
        help: 'Chat model id.',
      )
      ..addOption(
        'temperature',
        defaultsTo: '0.3',
        help: 'Chat sampling temperature.',
      )
      ..addOption(
        'max-tokens',
        defaultsTo: '2048',
        help: 'Maximum tokens in the answer.',
      )
      ..addFlag(
        'stream',
        defaultsTo: true,
        help: 'Stream the answer token-by-token (use --no-stream for batched).',
      )
      ..addFlag(
        'citations',
        defaultsTo: true,
        help: 'Print snippet citations after the answer.',
      );
  }

  @override
  String get name => 'ask';

  @override
  String get description =>
      'One-shot RAG: retrieve top-K snippets for a question, '
      'then answer with the chat broker.';

  @override
  String get invocation => '${runner!.executableName} $name <question>';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length != 1) {
      stderr.writeln(
        'ask: expected exactly one question argument.\n\n$usage',
      );
      return 64;
    }
    final question = args.rest.single;
    final collectionName = args['collection'] as String;
    final topK = int.parse(args['top-k'] as String);
    final chatBrokerId = args['broker'] as String;
    final chatModel = args['model'] as String;
    final temperature = double.parse(args['temperature'] as String);
    final maxTokens = int.parse(args['max-tokens'] as String);
    final shouldStream = args['stream'] as bool;
    final showCitations = args['citations'] as bool;
    final dbPath = (args['db'] as String?) ?? defaultWorkbenchDbPath();

    if (!File(dbPath).existsSync()) {
      stderr.writeln(
        'ask: no db at $dbPath. Run `ai_broker ingest` first.',
      );
      return 1;
    }

    final resolver = _keyResolverOverride ?? resolverFromArgs(args);

    // 1. Embed the question using the collection's pinned embed model,
    //    then run cosine top-K. Done synchronously while the store is
    //    open; closed before we hand off to the chat broker.
    final List<Hit> hits;
    final CollectionInfo info;
    final store = CorpusStore.openOrCreate(dbPath, readOnly: true);
    try {
      final maybeInfo = store.collection(collectionName);
      if (maybeInfo == null) {
        stderr.writeln('ask: collection "$collectionName" not found.');
        return 1;
      }
      info = maybeInfo;

      final embedBroker = _brokerFactory(info.embedBroker);
      if (embedBroker is! EmbedBroker) {
        stderr.writeln(
          'ask: broker "${info.embedBroker}" does not support embeddings.',
        );
        return 1;
      }
      final embedApiKey = await resolver.require(embedBroker.id);
      final embedder = Embedder(
        broker: embedBroker,
        apiKey: embedApiKey,
        model: info.embedModel,
      );
      final queryVec = await embedder.embedOne(question);

      hits = store.search(
        collection: collectionName,
        queryVector: queryVec,
        topK: topK,
      );
    } finally {
      store.close();
    }

    if (hits.isEmpty) {
      stderr.writeln(
        'ask: no matching snippets in collection "$collectionName".',
      );
      return 1;
    }

    // 2. Assemble the system prompt with numbered excerpts. The chat
    //    broker is instructed to cite back to [^N] indices that match
    //    the order printed here, so the citations section below maps
    //    1:1 with whatever the model emits inline.
    final systemPrompt = _buildSystemPrompt(hits);

    // 3. Chat — stream or batched depending on --stream.
    final chatBroker = _brokerFactory(chatBrokerId);
    if (chatBroker is! ChatBroker) {
      stderr.writeln(
        'ask: broker "$chatBrokerId" does not support chat.',
      );
      return 1;
    }
    final chatApiKey = await resolver.require(chatBroker.id);
    final request = ChatRequest(
      system: systemPrompt,
      messages: [AiMessage.user(question)],
      temperature: temperature,
      maxTokens: maxTokens,
    );

    if (shouldStream) {
      final tokens = chatBroker.stream(
        apiKey: chatApiKey,
        model: chatModel,
        request: request,
      );
      await for (final t in tokens) {
        stdout.write(t);
      }
      stdout.writeln();
    } else {
      final answer = await chatBroker.chat(
        apiKey: chatApiKey,
        model: chatModel,
        request: request,
      );
      stdout.writeln(answer);
    }

    if (showCitations) {
      stdout.writeln();
      stdout.writeln('— Sources ${'─' * 50}');
      for (var i = 0; i < hits.length; i++) {
        final h = hits[i];
        stdout.writeln(
          '[^${i + 1}] ${h.chunk.sourcePath}#${h.chunk.ord} '
          '(score ${h.score.toStringAsFixed(3)})',
        );
      }
    }

    return 0;
  }

  String _buildSystemPrompt(List<Hit> hits) {
    final buf = StringBuffer()
      ..writeln(
        'You answer using the following excerpts from the codebase as ground '
        'truth.',
      )
      ..writeln(
        'If the excerpts do not contain enough information to answer '
        'confidently, say so — do not invent details.',
      )
      ..writeln(
        'Cite sources inline as [^N] where N matches the bracketed index '
        'of the excerpt below.',
      )
      ..writeln();
    for (var i = 0; i < hits.length; i++) {
      final h = hits[i];
      buf
        ..writeln('[^${i + 1}] ${h.chunk.sourcePath}#${h.chunk.ord}')
        ..writeln(h.chunk.text)
        ..writeln();
    }
    return buf.toString();
  }
}
