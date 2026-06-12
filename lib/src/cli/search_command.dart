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

/// `aib search <query>` — embeds the query with the collection's pinned
/// model, returns cosine top-K snippets. Default output is human-
/// readable; `--json` produces a single JSON object suitable for
/// piping into Claude (slash-command style).
class SearchCommand extends Command<int> {
  final AiBroker Function(String) _brokerFactory;

  /// Test-only override. See [IngestCommand] for the resolution chain.
  final KeyResolver? _keyResolverOverride;

  SearchCommand({
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
        help: 'Collection to search.',
      )
      ..addOption(
        'top-k',
        abbr: 'k',
        defaultsTo: '8',
        help: 'Number of snippets to return.',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit a single JSON object instead of human-readable text.',
      )
      ..addOption(
        'db',
        help: 'SQLite path (default: \$AIB_DB or ~/.ai_broker/corpus.db).',
      );
  }

  @override
  String get name => 'search';

  @override
  String get description =>
      'Cosine top-K search over a collection. Outputs snippets for Claude.';

  @override
  String get invocation => '${runner!.executableName} $name <query>';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length != 1) {
      stderr.writeln(
        'search: expected exactly one query argument.\n\n$usage',
      );
      return 64;
    }
    final query = args.rest.single;
    final collectionName = args['collection'] as String;
    final topK = int.parse(args['top-k'] as String);
    final asJson = args['json'] as bool;
    final dbPath = (args['db'] as String?) ?? defaultWorkbenchDbPath();

    if (!File(dbPath).existsSync()) {
      stderr.writeln(
        'search: no db at $dbPath. Run `ai_broker ingest` first.',
      );
      return 1;
    }

    final store = CorpusStore.openOrCreate(dbPath, readOnly: true);
    try {
      final info = store.collection(collectionName);
      if (info == null) {
        stderr.writeln('search: collection "$collectionName" not found.');
        return 1;
      }

      final broker = _brokerFactory(info.embedBroker);
      if (broker is! EmbedBroker) {
        stderr.writeln(
          'search: broker "${info.embedBroker}" does not support embeddings.',
        );
        return 1;
      }
      final resolver = _keyResolverOverride ?? resolverFromArgs(args);
      final apiKey = await resolver.require(broker.id);
      final embedder = Embedder(
        broker: broker,
        apiKey: apiKey,
        model: info.embedModel,
      );
      final queryVec = await embedder.embedOne(query);
      final hits = store.search(
        collection: collectionName,
        queryVector: queryVec,
        topK: topK,
      );

      if (asJson) {
        _printJson(
          hits,
          query: query,
          collection: collectionName,
          info: info,
        );
      } else {
        _printText(hits, collection: collectionName);
      }
      return 0;
    } finally {
      store.close();
    }
  }

  void _printJson(
    List<Hit> hits, {
    required String query,
    required String collection,
    required CollectionInfo info,
  }) {
    final payload = <String, Object?>{
      'query': query,
      'collection': collection,
      'embed_broker': info.embedBroker,
      'embed_model': info.embedModel,
      'total_chunks': info.chunkCount,
      'hits': [
        for (final h in hits)
          {
            'score': h.score,
            'source_path': h.chunk.sourcePath,
            'ord': h.chunk.ord,
            'text': h.chunk.text,
            if (h.chunk.meta.isNotEmpty) 'meta': h.chunk.meta,
          },
      ],
    };
    stdout.writeln(jsonEncode(payload));
  }

  void _printText(List<Hit> hits, {required String collection}) {
    if (hits.isEmpty) {
      stdout.writeln('No results in collection "$collection".');
      return;
    }
    for (var i = 0; i < hits.length; i++) {
      final h = hits[i];
      stdout.writeln(
        '[${i + 1}] ${h.chunk.sourcePath}#${h.chunk.ord} '
        '(score ${h.score.toStringAsFixed(4)})',
      );
      stdout.writeln(h.chunk.text);
      stdout.writeln();
    }
  }
}
