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
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '/_common.dart';

/// `aib ingest <path>...` — reads text files, chunks them, embeds, and
/// writes into a `CorpusStore` collection.
class IngestCommand extends Command<int> {
  /// Factory used to resolve a broker id. Tests inject a fake; the CLI
  /// uses the default [brokerForId].
  final AiBroker Function(String) _brokerFactory;

  /// Test-only override. When null, the resolver is built from CLI args
  /// at run time via [resolverFromArgs] (`--openai-key`, `--env-file`,
  /// auto-detected `./.env`, then env vars).
  final KeyResolver? _keyResolverOverride;

  IngestCommand({
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
        help: 'Name of the collection to ingest into. '
            'First ingest pins the embed broker + model.',
      )
      ..addOption(
        'embed-broker',
        defaultsTo: 'openai',
        allowed: ['openai', 'gemini'],
        help: 'Provider that produces embeddings.',
      )
      ..addOption(
        'embed-model',
        defaultsTo: OpenAiBroker.defaultEmbedModel,
        help: 'Embedding model id.',
      )
      ..addOption(
        'chunk-size',
        defaultsTo: '800',
        help: 'Target chunk size in tokens (≈4 chars each).',
      )
      ..addOption(
        'chunk-overlap',
        defaultsTo: '150',
        help: 'Overlap between adjacent chunks in tokens.',
      )
      ..addOption(
        'db',
        help: 'SQLite path (default: \$AIB_DB or ~/.ai_broker/corpus.db).',
      )
      ..addOption(
        'ext',
        defaultsTo: '.txt,.md',
        help: 'Comma-separated extensions to ingest from directories (case-'
            'insensitive). e.g. ".dart,.md,.yaml" for a Dart codebase.',
      );
  }

  @override
  String get name => 'ingest';

  @override
  String get description =>
      'Chunk + embed text files, store them into a collection.';

  @override
  String get invocation => '${runner!.executableName} $name <path>...';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.isEmpty) {
      stderr.writeln(
        'ingest: at least one file or directory path required.\n\n$usage',
      );
      return 64;
    }

    final collectionName = args['collection'] as String;
    final brokerId = args['embed-broker'] as String;
    final embedModel = args['embed-model'] as String;
    final chunkTokens = int.parse(args['chunk-size'] as String);
    final overlapTokens = int.parse(args['chunk-overlap'] as String);
    final dbPath = (args['db'] as String?) ?? defaultWorkbenchDbPath();
    final extensions = (args['ext'] as String)
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toSet();

    final files = _expandTextFiles(args.rest, extensions);
    if (files.isEmpty) {
      stderr.writeln(
        'ingest: no files with extensions ${extensions.join(', ')} '
        'found under: ${args.rest.join(', ')}',
      );
      return 1;
    }

    final broker = _brokerFactory(brokerId);
    if (broker is! EmbedBroker) {
      stderr.writeln(
        'ingest: broker "$brokerId" does not support embeddings.\n'
        'Use --embed-broker openai or --embed-broker gemini.',
      );
      return 1;
    }
    final resolver = _keyResolverOverride ?? resolverFromArgs(args);
    final apiKey = await resolver.require(broker.id);
    final embedder = Embedder(
      broker: broker,
      apiKey: apiKey,
      model: embedModel,
    );

    _ensureDirExists(dbPath);
    final store = CorpusStore.openOrCreate(dbPath);
    try {
      // If the collection already exists, reuse its pinned dim — no need
      // to burn an embed call on a probe. Probe only on first ingest.
      final existing = store.collection(collectionName);
      final int dim;
      if (existing != null) {
        dim = existing.dim;
      } else {
        final probe = (await embedder.embedAll(const ['_dim_probe_'])).first;
        dim = probe.length;
      }
      store.upsertCollection(
        name: collectionName,
        embedBroker: broker.id,
        embedModel: embedModel,
        dim: dim,
      );

      final chunker = SentenceWindowChunker(
        targetChars: chunkTokens * 4,
        overlapChars: overlapTokens * 4,
      );

      var totalChunks = 0;
      var docsIngested = 0;
      var docsSkipped = 0;

      for (final file in files) {
        final text = await File(file).readAsString();
        final hash = sha256.convert(utf8.encode(text)).toString();

        // Skip BEFORE embedding so re-ingest doesn't burn an API call.
        if (store.hasDocument(
          collection: collectionName,
          sourcePath: file,
          contentHash: hash,
        )) {
          docsSkipped++;
          stdout.writeln(
            '${p.basename(file)}: skipped (already ingested).',
          );
          continue;
        }

        final chunks = chunker.chunk(text, sourcePath: file);
        if (chunks.isEmpty) {
          stdout.writeln('${p.basename(file)}: empty after trim, skipping.');
          continue;
        }
        stdout.write(
          '${p.basename(file)}: ${chunks.length} chunks → embedding... ',
        );
        final vectors = await embedder.embedAll(
          chunks.map((c) => c.text).toList(growable: false),
        );
        store.addDocument(
          collection: collectionName,
          sourcePath: file,
          contentHash: hash,
          chunks: chunks,
          vectors: vectors,
        );
        totalChunks += chunks.length;
        docsIngested++;
        stdout.writeln('done.');
      }

      final info = store.collection(collectionName)!;
      stdout.writeln(
        '\nCollection "$collectionName": '
        '${info.chunkCount} total chunks '
        '(${info.embedBroker}/${info.embedModel}, dim ${info.dim}).',
      );
      stdout.writeln(
        '+$docsIngested document(s), $docsSkipped skipped, '
        '$totalChunks new chunks.',
      );
      return 0;
    } finally {
      store.close();
    }
  }

  /// Expands [paths] into a flat list of files whose extensions are in
  /// [allowed]. Directories are walked recursively; missing paths are
  /// reported and skipped. Dot-prefixed dirs (e.g. `.git`, `.dart_tool`)
  /// are skipped entirely.
  List<String> _expandTextFiles(List<String> paths, Set<String> allowed) {
    final out = <String>[];
    for (final raw in paths) {
      final type = FileSystemEntity.typeSync(raw);
      if (type == FileSystemEntityType.notFound) {
        stderr.writeln('ingest: path not found: $raw');
        continue;
      }
      if (type == FileSystemEntityType.file) {
        if (allowed.contains(p.extension(raw).toLowerCase())) out.add(raw);
        continue;
      }
      if (type == FileSystemEntityType.directory) {
        final entries = Directory(
          raw,
        ).listSync(recursive: true, followLinks: false);
        for (final e in entries) {
          if (e is! File) continue;
          // Skip anything whose path crosses a dotted segment (.git/, .agents/,
          // .dart_tool/, etc.) — these aren't usually corpus material.
          final rel = p.relative(e.path, from: raw);
          if (p.split(rel).any((seg) => seg.startsWith('.'))) continue;
          if (allowed.contains(p.extension(e.path).toLowerCase())) {
            out.add(e.path);
          }
        }
      }
    }
    out.sort();
    return out;
  }

  void _ensureDirExists(String filePath) {
    final dir = Directory(p.dirname(filePath));
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }
}
