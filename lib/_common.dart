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

// Internal-only umbrella import. Files under lib/src/ import this as
// `import '/_common.dart';`. Bundle third-party APIs the package uses
// here so individual sources don't repeat the same imports.

export 'dart:async'
    show
        Completer,
        StreamController,
        StreamSubscription,
        Timer,
        TimeoutException;
export 'dart:convert' show jsonDecode, jsonEncode, utf8, LineSplitter;
// `Platform` is only read on native paths (EnvKeyResolver, the CLI).
export 'dart:io' show Platform;

export 'package:http/http.dart'
    show
        AbortableRequest,
        Client,
        ClientException,
        Request,
        RequestAbortedException,
        Response,
        StreamedResponse;
export 'package:meta/meta.dart' show immutable, protected, visibleForTesting;

export 'src/_src.dart';
