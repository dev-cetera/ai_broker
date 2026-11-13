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

/// DeepSeek (`https://api.deepseek.com`) — implements [ChatBroker] and
/// [KeyCheckBroker]. A preset of [OpenAiCompatibleBroker]; DeepSeek has no
/// embeddings endpoint, so pair it with [OpenAiBroker] or [GeminiBroker] for
/// the embed side of a RAG pipeline.
///
/// DeepSeek specifics, from its API reference:
/// - The token ceiling is `max_tokens`.
/// - `response_format` accepts only `text` and `json_object`, so
///   [ChatRequest.jsonSchema] is sent as JSON mode with the schema in the
///   system prompt. Parse the reply defensively.
/// - Thinking mode is on by default. [ChatRequest.effort] maps to
///   `reasoning_effort`; temperature has no effect while thinking.
/// - `tool_choice: required` and named tool choices are rejected in thinking
///   mode.
class DeepSeekBroker extends OpenAiCompatibleBroker {
  DeepSeekBroker({super.client, String? baseUrl})
      : super(
          id: 'deepseek',
          label: 'DeepSeek',
          baseUrl: baseUrl ?? 'https://api.deepseek.com',
          supportsJsonSchema: false,
        );
}
