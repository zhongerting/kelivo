import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/business_restore_service.dart';
import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/prompt_preset.dart';
import 'package:Kelivo/core/models/world_book.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/prompt_preset_provider.dart';
import 'package:Kelivo/core/providers/world_book_provider.dart';

import '../../support/business_test_harness.dart';

void main() {
  test('legacy assistant JSON keeps normal defaults', () {
    final assistant = Assistant.fromJson({
      'id': 'legacy',
      'name': 'Legacy',
      'systemPrompt': 'Keep me separate',
    });

    expect(assistant.mode, AssistantMode.normal);
    expect(assistant.characterPrompt, isEmpty);
    expect(assistant.firstMessage, isEmpty);
    expect(assistant.excludeThinkingFromContext, isFalse);
  });

  test(
    'roleplay fields round-trip through Assistant JSON and business backup',
    () async {
      final original = Assistant(
        id: 'rp-1',
        name: 'Mira',
        systemPrompt: 'Existing system rules',
        mode: AssistantMode.roleplay,
        characterPrompt: '<character_description>desc</character_description>',
        firstMessage: 'Hello {{user}}',
        excludeThinkingFromContext: true,
      );
      final roundTripped = Assistant.fromJson(original.toJson());

      expect(roundTripped.mode, AssistantMode.roleplay);
      expect(roundTripped.systemPrompt, 'Existing system rules');
      expect(roundTripped.characterPrompt, contains('desc'));
      expect(roundTripped.firstMessage, 'Hello {{user}}');
      expect(roundTripped.excludeThinkingFromContext, isTrue);

      final source = await createBusinessTestHarness(
        initial: {
          'assistants_v1': jsonEncode([original.toJson()]),
        },
      );
      final exported = await BusinessRestoreService(
        source.repository,
      ).exportSettings();
      final restored = await createBusinessTestHarness(initial: exported);
      final payload =
          jsonDecode(restored.preferences.getString('assistants_v1')!) as List;
      final restoredAssistant = Assistant.fromJson(
        (payload.single as Map).cast<String, dynamic>(),
      );

      expect(restoredAssistant.mode, AssistantMode.roleplay);
      expect(restoredAssistant.characterPrompt, original.characterPrompt);
      expect(restoredAssistant.excludeThinkingFromContext, isTrue);
    },
  );

  test(
    'duplicating and deleting an assistant maintains preset and world-book bindings',
    () async {
      final harness = await createBusinessTestHarness();
      final presets = PromptPresetProvider(preferences: harness.preferences);
      final books = WorldBookProvider(preferences: harness.preferences);
      await presets.initialize();
      await books.initialize();
      await presets.addPreset(
        const PromptPreset(
          id: 'preset-1',
          name: 'Preset',
          sourceFormat: PromptPresetSourceFormat.kelivo,
          entries: <PromptPresetEntry>[],
        ),
      );
      await books.addBook(
        const WorldBook(
          id: 'book-1',
          name: 'Book',
          entries: <WorldBookEntry>[],
        ),
      );
      final assistants = AssistantProvider(
        preferences: harness.preferences,
        promptPresetProvider: presets,
        worldBookProvider: books,
      );
      final id = await assistants.addAssistant(name: 'RP');
      await presets.setSelectedPresetId(id, 'preset-1');
      await books.setActiveBookIds(['book-1'], assistantId: id);

      final duplicateId = await assistants.duplicateAssistant(id);
      expect(duplicateId, isNotNull);
      expect(presets.selectedPresetIdFor(duplicateId), 'preset-1');
      expect(books.activeBookIdsFor(duplicateId), contains('book-1'));

      expect(await assistants.deleteAssistant(id), isTrue);
      expect(presets.selectedPresetIdFor(id), isNull);
      expect(books.activeBookIdsFor(id), isEmpty);
    },
  );
}
