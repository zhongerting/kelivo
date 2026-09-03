import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/prompt_preset.dart';
import 'package:Kelivo/core/providers/prompt_preset_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/logging/context_log_models.dart';
import 'package:Kelivo/core/services/logging/context_logger.dart';
import 'package:Kelivo/features/home/services/message_builder_service.dart';

import '../../../support/business_test_harness.dart';

class _PromptPresetChatService extends ChatService {}

class _FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PromptPresetEntry _entry({
  required String id,
  required String content,
  required int sourceOrder,
  required PromptPresetRole role,
  required PromptPresetAnchor anchor,
  bool enabled = true,
}) {
  return PromptPresetEntry(
    id: id,
    sourceIdentifier: id,
    name: id,
    content: content,
    enabled: enabled,
    role: role,
    anchor: anchor,
    sourceOrder: sourceOrder,
  );
}

PromptPreset _preset(List<PromptPresetEntry> entries) => PromptPreset(
  id: 'preset-1',
  name: 'Test preset',
  sourceFormat: PromptPresetSourceFormat.sillyTavern,
  entries: entries,
);

void main() {
  group('MessageBuilderService prompt presets', () {
    test('keeps role, source order, anchors, and sequential macros', () async {
      final harness = await createBusinessTestHarness();
      final provider = PromptPresetProvider(preferences: harness.preferences);
      await provider.initialize();
      await provider.addPreset(
        _preset([
          _entry(
            id: 'before-user',
            content: 'Before user: {{getvar::summary}}',
            sourceOrder: 1,
            role: PromptPresetRole.user,
            anchor: PromptPresetAnchor.beforeChatHistory,
          ),
          _entry(
            id: 'before-system',
            content:
                '{{setvar::summary::short summary}}Before {{user}}/{{char}}',
            sourceOrder: 0,
            role: PromptPresetRole.system,
            anchor: PromptPresetAnchor.beforeChatHistory,
          ),
          _entry(
            id: 'disabled-setvar',
            content: '{{setvar::summary::wrong}}',
            sourceOrder: 2,
            role: PromptPresetRole.system,
            anchor: PromptPresetAnchor.beforeChatHistory,
            enabled: false,
          ),
          _entry(
            id: 'after-assistant',
            content: 'After assistant: {{lastUserMessage}}',
            sourceOrder: 3,
            role: PromptPresetRole.assistant,
            anchor: PromptPresetAnchor.afterChatHistory,
          ),
          _entry(
            id: 'after-user',
            content: 'After user',
            sourceOrder: 4,
            role: PromptPresetRole.user,
            anchor: PromptPresetAnchor.afterChatHistory,
          ),
        ]),
      );
      await provider.setSelectedPresetId('assistant-1', 'preset-1');

      final service = MessageBuilderService(
        chatService: _PromptPresetChatService(),
        contextProvider: _FakeBuildContext(),
        promptPresetProvider: provider,
      );
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'Base system'},
        {'role': 'user', 'content': 'History user'},
        {'role': 'assistant', 'content': 'History assistant'},
      ];

      await service.injectPromptPresetPrompts(
        messages,
        assistantId: 'assistant-1',
        userName: 'Alice',
        charName: 'Archivist',
        lastUserMessage: 'Summarize this',
      );

      expect(messages.map((message) => message['role']), [
        'system',
        'system',
        'user',
        'user',
        'assistant',
        'assistant',
        'user',
      ]);
      expect(messages.map((message) => message['content']), [
        'Base system',
        'Before Alice/Archivist',
        'Before user: short summary',
        'History user',
        'History assistant',
        'After assistant: Summarize this',
        'After user',
      ]);
    });

    test(
      'disabled entries disappear on the next request and variables reset',
      () async {
        final harness = await createBusinessTestHarness();
        final provider = PromptPresetProvider(preferences: harness.preferences);
        await provider.initialize();
        await provider.addPreset(
          _preset([
            _entry(
              id: 'set',
              content: '{{setvar::x::enabled}}',
              sourceOrder: 0,
              role: PromptPresetRole.system,
              anchor: PromptPresetAnchor.beforeChatHistory,
            ),
            _entry(
              id: 'get',
              content: '{{getvar::x}}',
              sourceOrder: 1,
              role: PromptPresetRole.user,
              anchor: PromptPresetAnchor.afterChatHistory,
            ),
          ]),
        );
        await provider.setSelectedPresetId('assistant-1', 'preset-1');
        final service = MessageBuilderService(
          chatService: _PromptPresetChatService(),
          contextProvider: _FakeBuildContext(),
          promptPresetProvider: provider,
        );

        Future<List<Map<String, dynamic>>> build() async {
          final messages = <Map<String, dynamic>>[
            {'role': 'user', 'content': 'history'},
          ];
          await service.injectPromptPresetPrompts(
            messages,
            assistantId: 'assistant-1',
            userName: 'Alice',
            charName: 'Archivist',
            lastUserMessage: 'latest',
          );
          return messages;
        }

        expect((await build()).last['content'], 'enabled');
        await provider.setEntryEnabled(
          presetId: 'preset-1',
          entryId: 'set',
          enabled: false,
        );
        final disabled = await build();
        expect(disabled.map((message) => message['content']), ['history']);
      },
    );

    test('does not change messages without an explicit selection', () async {
      final harness = await createBusinessTestHarness();
      final provider = PromptPresetProvider(preferences: harness.preferences);
      await provider.initialize();
      await provider.addPreset(
        _preset([
          _entry(
            id: 'one',
            content: 'should not appear',
            sourceOrder: 0,
            role: PromptPresetRole.system,
            anchor: PromptPresetAnchor.beforeChatHistory,
          ),
        ]),
      );
      final service = MessageBuilderService(
        chatService: _PromptPresetChatService(),
        contextProvider: _FakeBuildContext(),
        promptPresetProvider: provider,
      );
      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'history'},
      ];
      await service.injectPromptPresetPrompts(
        messages,
        assistantId: 'assistant-without-selection',
        userName: 'Alice',
        charName: 'Archivist',
        lastUserMessage: 'latest',
      );
      expect(messages, [
        {'role': 'user', 'content': 'history'},
      ]);
    });

    test('tags inserted entries as promptPreset in Context Logger', () async {
      await ContextLogger.setEnabled(true);
      addTearDown(() => ContextLogger.setEnabled(false));
      final harness = await createBusinessTestHarness();
      final provider = PromptPresetProvider(preferences: harness.preferences);
      await provider.initialize();
      await provider.addPreset(
        _preset([
          _entry(
            id: 'logged',
            content: 'logged content',
            sourceOrder: 0,
            role: PromptPresetRole.assistant,
            anchor: PromptPresetAnchor.afterChatHistory,
          ),
        ]),
      );
      await provider.setSelectedPresetId('assistant-1', 'preset-1');
      final service = MessageBuilderService(
        chatService: _PromptPresetChatService(),
        contextProvider: _FakeBuildContext(),
        promptPresetProvider: provider,
      );
      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'history'},
      ];
      await service.injectPromptPresetPrompts(
        messages,
        assistantId: 'assistant-1',
        userName: 'Alice',
        charName: 'Archivist',
        lastUserMessage: 'latest',
      );

      final snapshot = ContextLogger.buildSnapshot(
        apiMessages: messages,
        conversationId: 'conversation-1',
        assistantName: 'Archivist',
        provider: 'test',
        model: 'model',
      );
      final presetSegment = snapshot.messages
          .expand((message) => message.segments)
          .firstWhere(
            (segment) => segment.source == ContextSource.promptPreset,
          );
      expect(presetSegment.text, 'logged content');
      expect(presetSegment.meta?['entryId'], 'logged');
      expect(presetSegment.meta?['anchor'], 'afterChatHistory');
    });
  });
}
