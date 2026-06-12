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
import 'package:args/command_runner.dart';

Future<void> main(List<String> args) async {
  final runner = buildAibRunner();
  try {
    final code = await runner.run(args);
    exit(code ?? 0);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  } on AiBrokerException catch (e) {
    // Provider-side failure (bad key, rate-limited after retries, etc.) —
    // print the message; stack trace would just be noise.
    stderr.writeln('ai_broker: $e');
    exit(1);
  } on MissingKeyException catch (e) {
    stderr.writeln('ai_broker: $e');
    exit(1);
  } on FormatException catch (e) {
    stderr.writeln('ai_broker: $e');
    exit(64);
  } catch (e, st) {
    // Unexpected — include the trace.
    stderr.writeln('ai_broker: $e');
    stderr.writeln(st);
    exit(1);
  }
}
