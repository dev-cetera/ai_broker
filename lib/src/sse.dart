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
Future<Stream<List<int>>> openSsePost({
  required Uri uri,
  required Map<String, String> headers,
  required String body,
  required String providerLabel,
  Client? client,
}) async {
  final ownsClient = client == null;
  final http = client ?? Client();
  StreamedResponse streamed;
  try {
    final req = Request('POST', uri);
    req.headers.addAll(headers);
    req.body = body;
    streamed = await http.send(req);
  } catch (_) {
    if (ownsClient) http.close();
    rethrow;
  }
  if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
    try {
      final buffered = await streamed.stream.bytesToString();
      throw AiBrokerException(
        '$providerLabel ${streamed.statusCode}: $buffered',
        statusCode: streamed.statusCode,
      );
    } finally {
      if (ownsClient) http.close();
    }
  }
  if (!ownsClient) return streamed.stream;
  // Wrap the byte stream so the ephemeral client is released exactly
  // once — whether the consumer drains, cancels, or hits an error.
  final controller = StreamController<List<int>>(sync: true);
  late StreamSubscription<List<int>> sub;
  var closed = false;
  void closeOnce() {
    if (closed) return;
    closed = true;
    http.close();
  }

  sub = streamed.stream.listen(
    controller.add,
    onError: (Object e, StackTrace s) {
      controller.addError(e, s);
    },
    onDone: () {
      closeOnce();
      controller.close();
    },
    cancelOnError: false,
  );
  controller
    ..onCancel = () async {
      await sub.cancel();
      closeOnce();
    }
    ..onPause = sub.pause
    ..onResume = sub.resume;
  return controller.stream;
}
