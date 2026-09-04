import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/utils/model_visible_history.dart';

void main() {
  const filteringAssistant = Assistant(
    id: 'rp-1',
    name: 'RP',
    excludeThinkingFromContext: true,
  );

  test('filters completed assistant text without mutating the message', () {
    final message = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: '<think>private plan</think>visible answer',
      conversationId: 'c1',
    );

    expect(
      ModelVisibleHistory.contentFor(message, assistant: filteringAssistant),
      'visible answer',
    );
    expect(message.content, '<think>private plan</think>visible answer');
  });

  test('keeps non-assistant, disabled, and processing messages unchanged', () {
    final user = ChatMessage(
      role: 'user',
      content: '<think>user text</think>keep',
      conversationId: 'c1',
    );
    final disabled = ChatMessage(
      id: 'a-disabled',
      role: 'assistant',
      content: '<think>private</think>keep',
      conversationId: 'c1',
    );
    final processing = ChatMessage(
      id: 'a-processing',
      role: 'assistant',
      content: '<think>active</think>keep',
      conversationId: 'c1',
      isStreaming: true,
    );

    expect(
      ModelVisibleHistory.contentFor(user, assistant: filteringAssistant),
      user.content,
    );
    expect(ModelVisibleHistory.contentFor(disabled), disabled.content);
    expect(
      ModelVisibleHistory.contentFor(processing, assistant: filteringAssistant),
      processing.content,
    );
    expect(
      ModelVisibleHistory.contentFor(
        disabled,
        assistant: filteringAssistant,
        processingMessageId: disabled.id,
      ),
      disabled.content,
    );
  });

  test('omits a reasoning-only completed assistant from text consumers', () {
    final message = ChatMessage(
      role: 'assistant',
      content: '<thinking>private only</thinking>',
      conversationId: 'c1',
    );

    expect(
      ModelVisibleHistory.contentFor(message, assistant: filteringAssistant),
      isEmpty,
    );
  });
}
