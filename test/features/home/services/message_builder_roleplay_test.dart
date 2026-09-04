import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/logging/context_log_models.dart';
import 'package:Kelivo/core/services/logging/context_logger.dart';
import 'package:Kelivo/features/home/services/message_builder_service.dart';

class _FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChatService extends ChatService {}

void main() {
  setUp(() async {
    await ContextLogger.setEnabled(false);
  });

  tearDown(() async {
    await ContextLogger.setEnabled(false);
  });

  test(
    'injects RP character settings independently and safely renders macros',
    () {
      final service = MessageBuilderService(
        chatService: _FakeChatService(),
        contextProvider: _FakeBuildContext(),
      );
      final assistant = const Assistant(
        id: 'rp-1',
        name: 'Archivist',
        mode: AssistantMode.roleplay,
        systemPrompt: 'base system',
        characterPrompt:
            '<character_description>Call {{char}}.</character_description> '
            'User: {{user}}. Unknown: {{execute::danger}}',
      );
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': assistant.systemPrompt},
        {'role': 'user', 'content': 'hello'},
      ];

      service.injectCharacterPrompt(messages, assistant, userName: 'Alice');

      expect(messages.map((message) => message['role']), [
        'system',
        'system',
        'user',
      ]);
      expect(messages.first['content'], 'base system');
      expect(messages[1]['content'], contains('Call Archivist.'));
      expect(messages[1]['content'], contains('User: Alice.'));
      expect(messages[1]['content'], contains('{{execute::danger}}'));
    },
  );

  test('does not inject character settings for normal assistants', () {
    final service = MessageBuilderService(
      chatService: _FakeChatService(),
      contextProvider: _FakeBuildContext(),
    );
    final messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'hello'},
    ];

    service.injectCharacterPrompt(
      messages,
      const Assistant(
        id: 'normal-1',
        name: 'Normal',
        characterPrompt: 'must not be injected',
      ),
      userName: 'Alice',
    );

    expect(messages, [
      {'role': 'user', 'content': 'hello'},
    ]);
  });

  test('logs character settings as a distinct context source', () async {
    await ContextLogger.setEnabled(true);
    final service = MessageBuilderService(
      chatService: _FakeChatService(),
      contextProvider: _FakeBuildContext(),
    );
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'base'},
    ];

    service.injectCharacterPrompt(
      messages,
      const Assistant(
        id: 'rp-1',
        name: 'Archivist',
        mode: AssistantMode.roleplay,
        characterPrompt: '{{char}} greets {{user}}',
      ),
      userName: 'Alice',
    );

    final snapshot = ContextLogger.buildSnapshot(
      apiMessages: messages,
      conversationId: Conversation(title: 'test').id,
      assistantName: 'Archivist',
      provider: 'test',
      model: 'model',
    );
    final characterSegment = snapshot.messages
        .expand((message) => message.segments)
        .firstWhere(
          (segment) => segment.source == ContextSource.characterPrompt,
        );
    expect(characterSegment.text, 'Archivist greets Alice');
  });
}
