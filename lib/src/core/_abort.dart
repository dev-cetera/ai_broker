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

// Internal: the plumbing behind every `abortTrigger` parameter.
//
// Two layers do the aborting. The request is sent as an `Abortable` one, so a
// client that supports it (`IOClient`, `BrowserClient`) closes the connection
// and the provider stops generating. On top of that, [AbortGuard.race] fails
// the caller's future the moment the trigger fires, so a client that ignores
// the trigger (a test fake, a custom `BaseClient`) still can't keep the caller
// waiting.

import '/_common.dart';

/// Watches one call's `abortTrigger`. With a `null` trigger every method is a
/// pass-through, so callers that never abort see exactly the old behaviour.
class AbortGuard {
  AbortGuard(this.trigger) {
    // The trigger must not complete with an error, but if it does that is
    // still a reason to stop, not something to report as unhandled.
    trigger?.then((_) => _fire(), onError: (Object _) => _fire());
  }

  final Future<void>? trigger;

  bool _fired = false;
  final List<void Function()> _onFire = [];

  /// Whether the trigger has completed.
  bool get fired => _fired;

  void _fire() {
    if (_fired) return;
    _fired = true;
    final callbacks = [..._onFire];
    _onFire.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  void _whenFired(void Function() callback) {
    if (_fired) {
      callback();
    } else {
      _onFire.add(callback);
    }
  }

  /// Throws [AiAbortedException] when the trigger had already completed
  /// before the call started, so nothing is sent.
  ///
  /// A completed future only tells its listeners on a later microtask, so
  /// this waits one turn for the listener the constructor registered.
  Future<void> throwIfFired() async {
    if (trigger == null) return;
    await Future<void>.value();
    if (_fired) throw const AiAbortedException();
  }

  /// [op], unless the trigger fires first: then the result fails with
  /// [AiAbortedException] at once, and whatever [op] does later is dropped.
  /// A late success is handed to [discard] so it can release what it holds
  /// (an unread response body keeps its connection open).
  ///
  /// A `RequestAbortedException` from [op] — the client honouring the
  /// trigger — is reported as [AiAbortedException] too.
  Future<T> race<T>(Future<T> op, {void Function(T value)? discard}) {
    if (trigger == null) return op;
    final out = Completer<T>();
    op.then(
      (value) {
        if (out.isCompleted) {
          discard?.call(value);
        } else {
          out.complete(value);
        }
      },
      onError: (Object e, StackTrace st) {
        if (out.isCompleted) return;
        out.completeError(
          e is RequestAbortedException ? const AiAbortedException() : e,
          st,
        );
      },
    );
    _whenFired(() {
      if (!out.isCompleted) {
        out.completeError(const AiAbortedException(), StackTrace.current);
      }
    });
    return out.future;
  }

  /// Waits [duration], or fails with [AiAbortedException] as soon as the
  /// trigger fires. The timer is cancelled on abort, so an aborted retry
  /// backoff doesn't keep a CLI process alive.
  Future<void> sleep(Duration duration) {
    if (trigger == null) return Future<void>.delayed(duration);
    final out = Completer<void>();
    final timer = Timer(duration, () {
      if (!out.isCompleted) out.complete();
    });
    _whenFired(() {
      timer.cancel();
      if (!out.isCompleted) {
        out.completeError(const AiAbortedException(), StackTrace.current);
      }
    });
    return out.future;
  }

  /// Runs [callback] once, when the trigger fires (at once if it already
  /// has). Does nothing without a trigger.
  void onAbort(void Function() callback) {
    if (trigger == null) return;
    _whenFired(callback);
  }
}

/// `client.post(uri, headers:, body:)`, but sent as an [AbortableRequest] when
/// [abortTrigger] is set. Without one it is the plain `post` call, so a
/// client that only overrides `post` keeps working.
Future<Response> postWithAbort(
  Client client,
  Uri uri, {
  required Map<String, String> headers,
  required String body,
  Future<void>? abortTrigger,
}) {
  if (abortTrigger == null) {
    return client.post(uri, headers: headers, body: body);
  }
  // Same order as `BaseClient.post`: headers first, so setting the body keeps
  // the caller's Content-Type and only adds the charset.
  final request = AbortableRequest('POST', uri, abortTrigger: abortTrigger)
    ..headers.addAll(headers)
    ..body = body;
  return client.send(request).then(Response.fromStream);
}
