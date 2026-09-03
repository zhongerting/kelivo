import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/prompt_preset.dart';
import 'package:Kelivo/features/prompt_preset/services/prompt_preset_macro_service.dart';

void main() {
  const context = PromptPresetMacroContext(
    userName: 'Alice',
    charName: 'Archivist',
    lastUserMessage: 'Please summarize this.',
  );

  group('PromptPresetMacroService', () {
    test('expands context macros, comments, and trim deterministically', () {
      expect(
        PromptPresetMacroService.render(
          '  {{USER}}/{{char}}/{{lastUserMessage}} {{// hidden}}{{trim}}  ',
          context: context,
        ),
        'Alice/Archivist/Please summarize this.',
      );
    });

    test(
      'processes variables in enabled source order and skips disabled setvar',
      () {
        final entries = [
          const PromptPresetEntry(
            id: 'one',
            sourceIdentifier: 'one',
            name: 'one',
            content: '{{setvar::summary::a short summary}}',
            enabled: true,
            role: PromptPresetRole.system,
            anchor: PromptPresetAnchor.beforeChatHistory,
            sourceOrder: 0,
          ),
          const PromptPresetEntry(
            id: 'two',
            sourceIdentifier: 'two',
            name: 'two',
            content: 'Summary: {{getvar::summary}}',
            enabled: true,
            role: PromptPresetRole.user,
            anchor: PromptPresetAnchor.afterChatHistory,
            sourceOrder: 1,
          ),
          const PromptPresetEntry(
            id: 'three',
            sourceIdentifier: 'three',
            name: 'three',
            content: '{{setvar::summary::bad value}}',
            enabled: false,
            role: PromptPresetRole.system,
            anchor: PromptPresetAnchor.beforeChatHistory,
            sourceOrder: 2,
          ),
          const PromptPresetEntry(
            id: 'four',
            sourceIdentifier: 'four',
            name: 'four',
            content: '{{getvar::summary}}',
            enabled: true,
            role: PromptPresetRole.assistant,
            anchor: PromptPresetAnchor.afterChatHistory,
            sourceOrder: 3,
          ),
        ];

        final rendered = PromptPresetMacroService.renderEnabledEntries(
          entries,
          context: context,
        );

        expect(rendered.map((entry) => entry.content), [
          'Summary: a short summary',
          'a short summary',
        ]);
        expect(rendered.map((entry) => entry.entry.id), ['two', 'four']);
      },
    );

    test('keeps unknown macros and reports their names', () {
      const raw = '{{system}} {{foo::bar}}';
      expect(PromptPresetMacroService.render(raw, context: context), raw);
      expect(PromptPresetMacroService.findUnsupportedMacroNames(raw), [
        'system',
        'foo',
      ]);
    });

    test('bounds recursive variable expansion', () {
      final variables = <String, String>{
        'a': '{{getvar::b}}',
        'b': '{{getvar::a}}',
      };
      final rendered = PromptPresetMacroService.render(
        '{{getvar::a}}',
        context: context,
        variables: variables,
      );

      expect(rendered.length, lessThan(100));
    });
  });
}
