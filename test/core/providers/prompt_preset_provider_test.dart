import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/business_restore_service.dart';
import 'package:Kelivo/core/models/prompt_preset.dart';
import 'package:Kelivo/core/providers/prompt_preset_provider.dart';

import '../../support/business_test_harness.dart';

PromptPreset _preset(String id, String name) => PromptPreset(
  id: id,
  name: name,
  sourceFormat: PromptPresetSourceFormat.sillyTavern,
  entries: [
    const PromptPresetEntry(
      id: 'entry-1',
      sourceIdentifier: 'source-1',
      name: 'Entry',
      content: 'Content',
      enabled: true,
      role: PromptPresetRole.system,
      anchor: PromptPresetAnchor.beforeChatHistory,
      sourceOrder: 0,
    ),
  ],
);

void main() {
  group('PromptPresetProvider', () {
    test('persists entries and one selected preset per assistant', () async {
      final harness = await createBusinessTestHarness();
      final provider = PromptPresetProvider(preferences: harness.preferences);
      await provider.initialize();
      await provider.addPreset(_preset('preset-a', 'A'));
      await provider.addPreset(_preset('preset-b', 'B'));

      await provider.setSelectedPresetId('assistant-a', 'preset-a');
      await provider.setSelectedPresetId('assistant-a', 'preset-b');
      await provider.setSelectedPresetId('assistant-b', 'preset-a');
      expect(provider.selectedPresetIdFor('assistant-a'), 'preset-b');
      expect(provider.selectedPresetIdFor('assistant-b'), 'preset-a');

      await provider.setEntryEnabled(
        presetId: 'preset-b',
        entryId: 'entry-1',
        enabled: false,
      );
      final reopened = PromptPresetProvider(preferences: harness.preferences);
      await reopened.initialize();
      expect(reopened.selectedPresetFor('assistant-a')?.name, 'B');
      expect(
        reopened.selectedPresetFor('assistant-a')!.entries.single.enabled,
        isFalse,
      );

      await reopened.setSelectedPresetId('assistant-a', null);
      expect(reopened.selectedPresetFor('assistant-a'), isNull);
    });

    test('deleting a preset removes every assistant reference', () async {
      final harness = await createBusinessTestHarness();
      final provider = PromptPresetProvider(preferences: harness.preferences);
      await provider.initialize();
      await provider.addPreset(_preset('preset-a', 'A'));
      await provider.addPreset(_preset('preset-b', 'B'));
      await provider.setSelectedPresetId('assistant-a', 'preset-a');
      await provider.setSelectedPresetId('assistant-b', 'preset-a');

      await provider.deletePreset('preset-a');

      expect(provider.selectedPresetFor('assistant-a'), isNull);
      expect(provider.selectedPresetFor('assistant-b'), isNull);
      expect(provider.presets.map((preset) => preset.id), ['preset-b']);
      expect(
        jsonDecode(
          harness.preferences.getString(
            'prompt_preset_active_by_assistant_v1',
          )!,
        ),
        isEmpty,
      );
    });

    test('exports and restores preset data and selections', () async {
      final source = await createBusinessTestHarness();
      final provider = PromptPresetProvider(preferences: source.preferences);
      await provider.initialize();
      await provider.addPreset(_preset('preset-a', 'A'));
      await provider.setSelectedPresetId('assistant-a', 'preset-a');
      final exported = await BusinessRestoreService(
        source.repository,
      ).exportSettings();

      expect(exported, contains('prompt_presets_v1'));
      expect(exported, contains('prompt_preset_active_by_assistant_v1'));

      final restored = await createBusinessTestHarness(initial: exported);
      final restoredProvider = PromptPresetProvider(
        preferences: restored.preferences,
      );
      await restoredProvider.initialize();
      expect(restoredProvider.presets.single.name, 'A');
      expect(restoredProvider.selectedPresetIdFor('assistant-a'), 'preset-a');
    });
  });
}
