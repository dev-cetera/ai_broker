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

/// Strips a markdown code fence from [text]. Model output for "give me
/// code" prompts usually arrives wrapped in ```` ```lang\n...\n``` ````,
/// even after an explicit "code only" instruction, and often with a
/// sentence of prose before or after the block. Call this on the broker's
/// raw text before parsing or writing it to a file.
///
/// Behaviour:
///  - If the trimmed text is one fenced block (starts with ```` ``` ````,
///    optionally followed by a language tag on the same line, and ends with
///    ```` ``` ````), the outermost fences are removed. Fences inside the
///    body are kept.
///  - Otherwise, the first fenced block is extracted: from the first line
///    that opens a fence to the next line that is only ```` ``` ````. Prose
///    before and after the block is dropped. A block that never closes
///    (a reply cut off mid-code) runs to the end of the text.
///  - Text with no fence at the start of a line is returned unchanged
///    (after a `.trim()`), as is a single-line ```` ```x``` ````.
String stripCodeFence(String text) {
  final out = text.trim();
  if (out.startsWith('```')) {
    final firstNewline = out.indexOf('\n');
    if (firstNewline == -1) return out;
    final body = out.substring(firstNewline + 1);
    if (body.endsWith('```')) {
      return body.substring(0, body.length - 3).trim();
    }
  }
  final opening = _openingFenceLine.firstMatch(out);
  if (opening == null) return out;
  final afterOpening = out.substring(opening.end);
  final closing = _closingFenceLine.firstMatch(afterOpening);
  final body =
      closing == null ? afterOpening : afterOpening.substring(0, closing.start);
  return body.trim();
}

/// A line that opens a fence: ```` ``` ```` plus an optional language tag,
/// up to and including its newline.
final _openingFenceLine = RegExp(r'^[ \t]*```[^`\n]*\n', multiLine: true);

/// A line that is only a closing fence.
final _closingFenceLine = RegExp(r'^[ \t]*```[ \t]*$', multiLine: true);
