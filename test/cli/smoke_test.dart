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

/// Pre-deployment smoke tests. These tests spawn the real binary
/// (`dart run bin/ai_broker.dart`) as a subprocess to catch failures
/// the unit tests can't see: a missing `bin/` entry, broken pubspec
/// wiring, runtime import errors at the top level, etc.
///
/// They are slow (~5-10s each because Dart has to compile the script
/// on each invocation) but they are exactly what should gate a release.
/// If `dart test` is green and these pass, the published CLI will at
/// least *start*.
library;

import 'dart:io';

import 'package:test/test.dart';

const _entrypoint = 'bin/ai_broker.dart';

Future<ProcessResult> _runCli(List<String> args) {
  return Process.run('dart', ['run', _entrypoint, ...args]);
}

void main() {
  group('CLI smoke (subprocess)', () {
    // These tests have to compile the script each time → bump timeout.
    final smokeTimeout = const Timeout(Duration(minutes: 2));

    test(
      'pubspec declares both `ai_broker` and `aib` executables',
      () async {
        final pubspec = File('pubspec.yaml').readAsStringSync();
        expect(
          pubspec,
          contains('executables:'),
          reason: 'pubspec must declare an executables section so '
              '`dart pub global activate ai_broker` exposes the CLI.',
        );
        // Both binary names must be present so consumers can use
        // either the long or short form.
        expect(pubspec, contains('ai_broker:'));
        expect(pubspec, contains('aib:'));
      },
    );

    test(
      'binary starts and --help lists every shipped subcommand',
      timeout: smokeTimeout,
      () async {
        final result = await _runCli(['--help']);
        expect(
          result.exitCode,
          0,
          reason: 'exit ${result.exitCode}\n'
              'stdout: ${result.stdout}\nstderr: ${result.stderr}',
        );
        final out = '${result.stdout}\n${result.stderr}';
        for (final cmd in [
          'ingest',
          'search',
          'ask',
          'translate',
          'collections',
        ]) {
          expect(
            out,
            contains(cmd),
            reason: 'subcommand "$cmd" missing from --help output',
          );
        }
      },
    );

    test(
      'each subcommand has working --help',
      timeout: smokeTimeout,
      () async {
        for (final cmd in [
          'ingest',
          'search',
          'ask',
          'translate',
          'collections',
        ]) {
          final result = await _runCli([cmd, '--help']);
          expect(
            result.exitCode,
            0,
            reason: '$cmd --help failed: exit ${result.exitCode}\n'
                'stderr: ${result.stderr}',
          );
        }
      },
    );

    test(
      'unknown subcommand exits non-zero with a clean message',
      timeout: smokeTimeout,
      () async {
        final result = await _runCli(['definitely-not-a-real-command']);
        expect(result.exitCode, isNot(0));
        // CommandRunner emits its usage banner — confirm we surface
        // some hint about it rather than printing a raw stack trace.
        expect(result.stderr, isNot(contains('#0      ')));
      },
    );
  });
}
