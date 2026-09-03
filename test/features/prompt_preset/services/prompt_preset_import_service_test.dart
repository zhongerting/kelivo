import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/prompt_preset.dart';
import 'package:Kelivo/features/prompt_preset/services/prompt_preset_import_service.dart';

void main() {
  group('PromptPresetImportService', () {
    test('imports the minimal SillyTavern fixture in prompt_order order', () {
      final decoded = jsonDecode(
        File(
          'samples/sillytavern-minimal-prompt-preset.json',
        ).readAsStringSync(),
      );
      final result = PromptPresetImportService.parse(
        decoded,
        fallbackName: 'sillytavern-minimal-prompt-preset',
      );

      expect(result, isNotNull);
      expect(result!.format, PromptPresetImportFormat.sillyTavern);
      expect(result.importedEntries, 3);
      expect(result.enabledEntries, 2);
      expect(result.disabledEntries, 1);
      expect(result.skippedMarkers, 1);
      expect(result.skippedPluginEntries, 1);
      expect(result.unorderedEntries, 1);
      expect(result.preset.entries.map((entry) => entry.sourceIdentifier), [
        'system-main',
        'user-after-history',
        'assistant-after-history',
      ]);
      expect(result.preset.entries[0].enabled, isFalse);
      expect(
        result.preset.entries[0].anchor,
        PromptPresetAnchor.beforeChatHistory,
      );
      expect(
        result.preset.entries[1].anchor,
        PromptPresetAnchor.afterChatHistory,
      );
      expect(result.preset.entries[2].role, PromptPresetRole.assistant);
      expect(result.preset.toJson(), isNot(contains('extensions')));
    });

    test('matches the sanitized full-sample import baseline', () {
      final prompts = <Map<String, Object?>>[
        for (var i = 0; i < 59; i++)
          {
            'identifier': 'prompt-$i',
            'role': i.isEven ? 'system' : 'user',
            'enabled': i < 40,
            'content': 'fixture prompt $i',
          },
        for (var i = 0; i < 8; i++)
          {'identifier': 'marker-$i', 'marker': true, 'content': ''},
        {
          'identifier': 'SPresetSettings',
          'role': 'system',
          'content': 'plugin configuration must not be imported',
        },
      ];
      final order = <Map<String, Object?>>[
        for (var i = 0; i < 59; i++)
          {'identifier': 'prompt-$i', 'enabled': i < 40},
        for (var i = 0; i < 8; i++) {'identifier': 'marker-$i'},
      ];

      final result = PromptPresetImportService.parse({
        'prompts': prompts,
        'prompt_order': [
          {'character_id': 100001, 'order': order},
        ],
        'extensions': {
          'regex_scripts': 'must never execute',
          'SPreset': {'RegexBinding': 'must never execute'},
          'tavern_helper': {'scripts': 'must never execute'},
        },
      }, fallbackName: 'sanitized-full-sample');

      expect(result, isNotNull);
      expect(result!.preset.entries, hasLength(59));
      expect(result.enabledEntries, 40);
      expect(result.disabledEntries, 19);
      expect(result.skippedMarkers, 8);
      expect(result.skippedPluginEntries, 1);
      expect(result.unorderedEntries, 1);
      expect(result.preset.toJson(), isNot(contains('extensions')));
    });

    test(
      'selects character 100001 and applies order enabled over prompt enabled',
      () {
        final result = PromptPresetImportService.parse({
          'prompts': [
            {
              'identifier': 'a',
              'role': 'user',
              'enabled': true,
              'content': 'A',
            },
            {
              'identifier': 'b',
              'role': 'assistant',
              'enabled': false,
              'content': 'B',
            },
          ],
          'prompt_order': [
            {
              'character_id': 100000,
              'order': [
                {'identifier': 'b', 'enabled': true},
              ],
            },
            {
              'character_id': 100001,
              'order': [
                {'identifier': 'a', 'enabled': false},
                {'identifier': 'b', 'enabled': true},
              ],
            },
          ],
        }, fallbackName: 'Preset');

        expect(result, isNotNull);
        expect(result!.preset.entries, hasLength(2));
        expect(result.preset.entries.map((entry) => entry.sourceOrder), [0, 1]);
        expect(result.preset.entries.map((entry) => entry.enabled), [
          isFalse,
          isTrue,
        ]);
        expect(result.preset.entries.map((entry) => entry.role), [
          PromptPresetRole.user,
          PromptPresetRole.assistant,
        ]);
      },
    );

    test(
      'reports markers, malformed references, empty content, and duplicates',
      () {
        final result = PromptPresetImportService.parse({
          'prompts': [
            {'identifier': 'duplicate', 'content': 'first'},
            {'identifier': 'duplicate', 'content': 'second'},
            {'identifier': 'empty', 'content': '  '},
            {'identifier': 'marker', 'marker': true, 'content': ''},
          ],
          'prompt_order': [
            {
              'order': [
                {'identifier': 'marker'},
                {'identifier': 'duplicate', 'enabled': true},
                {'identifier': 'duplicate', 'enabled': true},
                {'identifier': 'empty', 'enabled': true},
                {'identifier': 'missing', 'enabled': true},
              ],
            },
          ],
        }, fallbackName: 'Preset');

        expect(result, isNotNull);
        expect(result!.preset.entries, isEmpty);
        expect(result.skippedMarkers, 1);
        expect(result.duplicateIdentifiers, greaterThanOrEqualTo(2));
        expect(result.missingIdentifiers, 1);
        expect(result.skippedEntries, greaterThanOrEqualTo(4));
      },
    );

    test('rejects JSON without prompts and a valid prompt_order', () {
      expect(
        PromptPresetImportService.parse({
          'prompts': [],
          'prompt_order': [],
        }, fallbackName: 'Preset'),
        isNull,
      );
      expect(
        PromptPresetImportService.parse({
          'prompts': [],
          'prompt_order': [{}],
        }, fallbackName: 'Preset'),
        isNull,
      );
    });

    test('treats a bare chatHistory identifier as a marker boundary', () {
      final result = PromptPresetImportService.parse({
        'prompts': [
          {'identifier': 'before', 'role': 'user', 'content': 'before history'},
          {
            'identifier': 'after',
            'role': 'assistant',
            'content': 'after history',
          },
        ],
        'prompt_order': [
          {
            'order': [
              {'identifier': 'before'},
              {'identifier': 'chatHistory'},
              {'identifier': 'after'},
            ],
          },
        ],
      }, fallbackName: 'Preset');

      expect(result, isNotNull);
      expect(result!.skippedMarkers, 1);
      expect(result.preset.entries.map((entry) => entry.anchor), [
        PromptPresetAnchor.beforeChatHistory,
        PromptPresetAnchor.afterChatHistory,
      ]);
    });

    test('falls back to prompt enabled when order enabled is absent', () {
      final result = PromptPresetImportService.parse({
        'prompts': [
          {'identifier': 'disabled', 'enabled': false, 'content': 'disabled'},
          {'identifier': 'enabled', 'enabled': true, 'content': 'enabled'},
        ],
        'prompt_order': [
          {
            'order': [
              {'identifier': 'disabled'},
              {'identifier': 'enabled'},
            ],
          },
        ],
      }, fallbackName: 'Preset');

      expect(result, isNotNull);
      expect(result!.preset.entries.map((entry) => entry.enabled), [
        isFalse,
        isTrue,
      ]);
    });
  });
}
