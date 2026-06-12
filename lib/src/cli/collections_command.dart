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

/// `aib collections` — lists collections in the workbench DB. The
/// `--exists <name>` flag turns it into a script-friendly probe: exit 0
/// if present, exit 1 if not, no output.
class CollectionsCommand extends Command<int> {
  CollectionsCommand() {
    argParser
      ..addOption(
        'db',
        help: 'SQLite path (default: \$AIB_DB or ~/.ai_broker/corpus.db).',
      )
      ..addOption(
        'exists',
        help: 'Probe mode: exit 0 if the named collection exists, 1 otherwise. '
            'Used by setup scripts that conditionally re-ingest.',
      );
  }

  @override
  String get name => 'collections';

  @override
  String get description => 'List collections in the workbench DB.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final dbPath = (args['db'] as String?) ?? defaultWorkbenchDbPath();
    final exists = args['exists'] as String?;

    if (!File(dbPath).existsSync()) {
      if (exists != null) return 1;
      stdout.writeln('(no collections — db not initialized at $dbPath)');
      return 0;
    }

    final store = CorpusStore.openOrCreate(dbPath, readOnly: true);
    try {
      if (exists != null) {
        return store.collection(exists) == null ? 1 : 0;
      }
      final cs = store.collections;
      if (cs.isEmpty) {
        stdout.writeln('(no collections in $dbPath)');
        return 0;
      }
      for (final c in cs) {
        stdout.writeln(
          '${c.name.padRight(30)} '
          '${c.embedBroker}/${c.embedModel}  '
          'dim=${c.dim}  chunks=${c.chunkCount}',
        );
      }
      return 0;
    } finally {
      store.close();
    }
  }
}
