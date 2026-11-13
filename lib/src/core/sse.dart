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

import '/_common.dart';
import '_abort.dart';

/// One parsed Server-Sent Event. OpenAI and Anthropic both use SSE for
/// their streaming endpoints (Gemini uses a JSON-array stream — see
/// the Gemini broker for that codepath).
///
/// [event] is the SSE event name (Anthropic uses it heavily —
/// `content_block_delta`, `message_stop`, etc.; OpenAI rarely sets it).
/// [data] is the raw payload string — usually JSON.
class SseEvent {
  final String? event;
  final String data;
  const SseEvent({this.event, required this.data});
}

/// Decodes a UTF-8 byte stream into [SseEvent]s. Buffers across chunk
/// boundaries (one event may span several `Stream<List<int>>` chunks),
/// joins multi-line `data:` payloads with `\n` per the SSE spec, and
/// filters out keep-alive comments.
Stream<SseEvent> decodeSseStream(Stream<List<int>> source) async* {
  final lines = source.transform(utf8.decoder).transform(const LineSplitter());
  String? eventName;
  final dataBuf = StringBuffer();
  await for (final line in lines) {
    if (line.isEmpty) {
      // Blank line = dispatch.
      if (dataBuf.isNotEmpty || eventName != null) {
        yield SseEvent(event: eventName, data: dataBuf.toString());
        eventName = null;
        dataBuf.clear();
      }
      continue;
    }
    if (line.startsWith(':')) continue; // SSE comment / keep-alive.
    if (line.startsWith('event:')) {
      eventName = line.substring(6).trim();
      continue;
    }
    if (line.startsWith('data:')) {
      // Strip exactly one leading space per spec.
      var chunk = line.substring(5);
      if (chunk.startsWith(' ')) chunk = chunk.substring(1);
      if (dataBuf.isNotEmpty) dataBuf.write('\n');
      dataBuf.write(chunk);
      continue;
    }
    // Other fields (id:, retry:) ignored — we only need event/data.
  }
  // Stream ended on a non-blank trailing line — flush.
  if (dataBuf.isNotEmpty || eventName != null) {
    yield SseEvent(event: eventName, data: dataBuf.toString());
  }
}

/// Opens a POST request and returns the response body as a byte
/// stream. Throws [AiBrokerException] on non-2xx (the body is buffered
/// in that path so we can include the error message).
///
/// When [client] is omitted, an ephemeral [Client] is created and
/// closed automatically once the returned stream ends, errors, or the
/// initial connect throws — so the caller never has to manage it.
/// Passing [client] keeps the lifecycle with the caller (every broker
/// in this package reuses its own long-lived client this way).
///
/// When [abortTrigger] completes, the request is aborted: before the
/// response arrives this throws [AiAbortedException]; while the body is
/// streaming, the returned stream emits [AiAbortedException] and closes, and
/// the underlying response is cancelled so the connection is released. A
/// trigger that has already completed throws before anything is sent.
Future<Stream<List<int>>> openSsePost({
  required Uri uri,
  required Map<String, String> headers,
  required String body,
  required String providerLabel,
  Client? client,
  Future<void>? abortTrigger,
}) async {
  final guard = AbortGuard(abortTrigger);
  if (abortTrigger != null) await guard.throwIfFired();
  final ownsClient = client == null;
  final http = client ?? Client();
  StreamedResponse streamed;
  try {
    final req = abortTrigger == null
        ? Request('POST', uri)
        : AbortableRequest('POST', uri, abortTrigger: abortTrigger);
    req.headers.addAll(headers);
    req.body = body;
    streamed = await guard.race(
      http.send(req),
      // A response that lands after the abort is never read; cancel it so a
      // client that ignored the trigger still lets go of the connection.
      discard: (late) =>
          late.stream.listen(null, onError: (Object _) {}).cancel(),
    );
  } catch (_) {
    if (ownsClient) http.close();
    rethrow;
  }
  if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
    try {
      final buffered = await guard.race(streamed.stream.bytesToString());
      throw AiBrokerException(
        '$providerLabel ${streamed.statusCode}: $buffered',
        statusCode: streamed.statusCode,
      );
    } finally {
      if (ownsClient) http.close();
    }
  }
  if (!ownsClient && abortTrigger == null) return streamed.stream;
  // Wrap the byte stream so the ephemeral client is released exactly
  // once — whether the consumer drains, cancels, or hits an error — and so
  // an abort ends it with [AiAbortedException] even when the client does
  // not honour the trigger itself.
  final controller = StreamController<List<int>>(sync: true);
  late StreamSubscription<List<int>> sub;
  var closed = false;
  void closeOnce() {
    if (closed) return;
    closed = true;
    if (ownsClient) http.close();
  }

  void abort() {
    if (controller.isClosed) return;
    controller.addError(const AiAbortedException(), StackTrace.current);
    sub.cancel().ignore();
    closeOnce();
    controller.close().ignore();
  }

  sub = streamed.stream.listen(
    (chunk) {
      if (!controller.isClosed) controller.add(chunk);
    },
    onError: (Object e, StackTrace s) {
      // The client honouring the trigger: report it the same way as ours.
      if (e is RequestAbortedException) return abort();
      if (!controller.isClosed) controller.addError(e, s);
    },
    onDone: () {
      closeOnce();
      if (!controller.isClosed) controller.close();
    },
    cancelOnError: false,
  );
  guard.onAbort(abort);
  controller
    ..onCancel = () async {
      await sub.cancel();
      closeOnce();
    }
    ..onPause = sub.pause
    ..onResume = sub.resume;
  return controller.stream;
}
