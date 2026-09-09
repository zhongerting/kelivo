import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/utils/reply_options_selector.dart';

ChatMessage _message({
  required String id,
  required String role,
  required int version,
  List<MessagePart> parts = const <MessagePart>[],
  bool isStreaming = false,
  String conversationId = 'conversation',
  String groupId = 'reply',
}) {
  return ChatMessage(
    id: id,
    role: role,
    conversationId: conversationId,
    groupId: groupId,
    version: version,
    isStreaming: isStreaming,
    parts: parts,
  );
}

void main() {
  test('selects options from the selected completed assistant version', () {
    final messages = [
      _message(id: 'user', role: 'user', version: 0, groupId: 'user'),
      _message(
        id: 'assistant-old',
        role: 'assistant',
        version: 0,
        parts: [
          const TextPart('old'),
          ReplyOptionsPart(assistantId: 'a1', options: ['old option']),
        ],
      ),
      _message(
        id: 'assistant-new',
        role: 'assistant',
        version: 1,
        parts: [
          const TextPart('new'),
          ReplyOptionsPart(assistantId: 'a1', options: ['new option']),
        ],
      ),
    ];

    expect(
      selectReplyOptions(
        messages: messages,
        versionSelections: const {'reply': 0},
        assistantId: 'a1',
      ),
      ['old option'],
    );
    expect(
      selectReplyOptions(
        messages: messages,
        versionSelections: const {},
        assistantId: 'a1',
      ),
      ['new option'],
    );
  });

  test('requires the last selected message to be a completed assistant', () {
    final assistant = _message(
      id: 'assistant',
      role: 'assistant',
      version: 0,
      parts: [
        const TextPart('reply'),
        ReplyOptionsPart(assistantId: 'a1', options: ['continue']),
      ],
    );
    final user = _message(
      id: 'user',
      role: 'user',
      version: 0,
      groupId: 'user',
      parts: const [TextPart('follow-up')],
    );

    expect(
      selectReplyOptions(
        messages: [assistant, user],
        versionSelections: const {},
        assistantId: 'a1',
      ),
      isEmpty,
    );
    expect(
      selectReplyOptions(
        messages: [assistant.copyWith(isStreaming: true)],
        versionSelections: const {},
        assistantId: 'a1',
      ),
      isEmpty,
    );
  });

  test('hides options for another assistant or transient UI state', () {
    final message = _message(
      id: 'assistant',
      role: 'assistant',
      version: 0,
      parts: [
        const TextPart('reply'),
        ReplyOptionsPart(assistantId: 'a1', options: ['continue']),
      ],
    );
    for (final flags in [
      const <String, bool>{'conversationSwitching': true},
      const <String, bool>{'assistantSwitching': true},
      const <String, bool>{'selectingMessages': true},
      const <String, bool>{'sending': true},
    ]) {
      expect(
        selectReplyOptions(
          messages: [message],
          versionSelections: const {},
          assistantId: 'a1',
          conversationSwitching: flags['conversationSwitching'] ?? false,
          assistantSwitching: flags['assistantSwitching'] ?? false,
          selectingMessages: flags['selectingMessages'] ?? false,
          sending: flags['sending'] ?? false,
        ),
        isEmpty,
      );
    }
    expect(
      selectReplyOptions(
        messages: [message],
        versionSelections: const {},
        assistantId: 'a2',
      ),
      isEmpty,
    );
  });
}
