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

import 'package:ai_broker/ai_broker.dart';
import 'package:test/test.dart';

void main() {
  group('AiCompletion', () {
    test('compares by value', () {
      const a = AiCompletion(
        text: 't',
        rawFinishReason: 'STOP',
        finishReason: AiFinishReason.stop,
        inputTokens: 1,
        outputTokens: 2,
        thinkingTokens: 0,
      );
      const b = AiCompletion(
        text: 't',
        rawFinishReason: 'STOP',
        finishReason: AiFinishReason.stop,
        inputTokens: 1,
        outputTokens: 2,
        thinkingTokens: 0,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          const AiCompletion(
            text: 't',
            rawFinishReason: 'MAX_TOKENS',
            finishReason: AiFinishReason.maxTokens,
            inputTokens: 1,
            outputTokens: 2,
            thinkingTokens: 0,
          ),
        ),
      );
    });
  });
}
