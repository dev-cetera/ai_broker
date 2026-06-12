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

import 'dart:convert';
import 'dart:io';

import 'package:ai_broker/ai_broker.dart';
import 'package:test/test.dart';

/// Returns a unit vector along axis [k] in [dim]-d space.
List<List<double>> _axisVector(int dim, int k) {
  return [
    [for (var i = 0; i < dim; i++) i == k ? 1.0 : 0.0],
  ];
}

/// Broker whose embedding picks an axis based on a keyword in the
/// input — so we can write deterministic similarity assertions.
class _KeywordBroker implements EmbedBroker {
  @override
  String get id => 'openai';
  @override
  String get label => 'KW';

  @override
  Future<List<String>> listModels(String apiKey) async => const [];

  @override
  Future<List<List<double>>> embed({
    required String apiKey,
    required String model,
    required List<String> inputs,
  }) async {
    final out = <List<double>>[];
    for (final s in inputs) {
      final lower = s.toLowerCase();
      int axis;
      if (lower.contains('apple')) {
        axis = 0;
      } else if (lower.contains('banana')) {
        axis = 1;
      } else {
        axis = 2;
      }
      out.add(_axisVector(3, axis).single);
    }
    return out;
  }
}

void main() {
  group('SearchCommand end-to-end', () {
    late Directory tmp;
    late String dbPath;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('aib_search_test_');
      dbPath = '${tmp.path}/corpus.db';

      File('${tmp.path}/fruits.md').writeAsStringSync(
        'An apple is a red fruit. '
        'A banana is yellow. '
        'A cabbage is leafy.',
      );

      final fake = _KeywordBroker();
      final runner = buildAibRunner(
        brokerFactory: (_) => fake,
        keyResolver: MapKeyResolver({'openai': 'sk-test'}),
      );
      await runner.run([
        'ingest',
        '--collection',
        'fruits',
        '--db',
        dbPath,
        '--chunk-size',
        '8',
        '--chunk-overlap',
        '0',
        '${tmp.path}/fruits.md',
      ]);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('returns the most-similar chunk first', () async {
      final out = StringBuffer();
      await IOOverrides.runZoned(
        () async {
          final runner = buildAibRunner(
            brokerFactory: (_) => _KeywordBroker(),
            keyResolver: MapKeyResolver({'openai': 'sk-test'}),
          );
          final code = await runner.run([
            'search',
            '--collection',
            'fruits',
            '--db',
            dbPath,
            '--top-k',
            '1',
            '--json',
            'I want an apple',
          ]);
          expect(code, 0);
        },
        stdout: () => _BufferingStdout(out),
      );

      final json = jsonDecode(out.toString().trim()) as Map<String, Object?>;
      final hits = json['hits'] as List<Object?>;
      expect(hits, hasLength(1));
      final top = hits.first as Map<String, Object?>;
      expect((top['text'] as String).toLowerCase(), contains('apple'));
    });

    test('missing collection returns non-zero exit', () async {
      final runner = buildAibRunner(
        brokerFactory: (_) => _KeywordBroker(),
        keyResolver: MapKeyResolver({'openai': 'sk-test'}),
      );
      final code = await runner.run([
        'search',
        '--collection',
        'nope',
        '--db',
        dbPath,
        'anything',
      ]);
      expect(code, 1);
    });

    test('missing db returns non-zero exit', () async {
      final runner = buildAibRunner(
        brokerFactory: (_) => _KeywordBroker(),
        keyResolver: MapKeyResolver({'openai': 'sk-test'}),
      );
      final code = await runner.run([
        'search',
        '--db',
        '${tmp.path}/does_not_exist.db',
        'q',
      ]);
      expect(code, 1);
    });
  });
}

/// Minimal stdout capture for verifying `--json` output without spawning
/// a subprocess.
class _BufferingStdout implements Stdout {
  final StringBuffer _buf;
  _BufferingStdout(this._buf);

  @override
  void write(Object? object) => _buf.write(object);
  @override
  void writeln([Object? object = '']) => _buf.writeln(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buf.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buf.writeCharCode(charCode);

  @override
  Encoding get encoding => utf8;
  @override
  set encoding(Encoding _) {}

  @override
  bool get hasTerminal => false;
  @override
  IOSink get nonBlocking => this as IOSink;
  @override
  bool get supportsAnsiEscapes => false;
  @override
  int get terminalColumns => 80;
  @override
  int get terminalLines => 24;
  @override
  Future<void> get done async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> flush() async {}

  @override
  void add(List<int> data) => _buf.write(utf8.decode(data));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  // The rest are unused for our tests; throw so missed calls are visible.
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_BufferingStdout.${invocation.memberName}');
}
