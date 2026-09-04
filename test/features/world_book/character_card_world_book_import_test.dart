import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/world_book.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/world_book_provider.dart';
import 'package:Kelivo/features/character_card/services/character_card_import_coordinator.dart';
import 'package:Kelivo/features/character_card/services/character_card_import_service.dart';
import 'package:Kelivo/features/world_book/services/world_book_import_service.dart';

import '../../support/business_test_harness.dart';

void main() {
  test('keeps real SillyTavern default fields enabled conservatively', () {
    final sample = jsonDecode(
      File(
        'test/features/world_book/fixtures/sillytavern_character_card_default_fields.json',
      ).readAsStringSync(),
    );
    final result = WorldBookImportService.parse(
      sample,
      policy: WorldBookImportPolicy.characterCard,
    );

    expect(result, isNotNull);
    expect(result!.book.entries, hasLength(15));
    expect(result.book.entries.where((entry) => entry.enabled), hasLength(3));
    expect(result.book.entries.where((entry) => !entry.enabled), hasLength(12));
    expect(result.skippedEntries, 0);
    expect(result.hasUnsupportedSettings, isTrue);
    expect(result.book.entries[0].enabled, isTrue);
    expect(result.book.entries[0].role, WorldBookInjectionRole.user);
    expect(result.book.entries[0].keywords, ['lantern']);
    expect(result.book.entries[1].enabled, isTrue);
    expect(result.book.entries[2].enabled, isFalse);
    expect(result.book.entries[8].enabled, isFalse);
    expect(result.book.entries[9].enabled, isTrue);
    expect(result.book.entries[9].keywords, ['lantern']);
    expect(result.book.entries[9].useRegex, isFalse);
    expect(result.book.entries[10].enabled, isFalse);
    expect(result.book.entries[11].enabled, isFalse);
    expect(result.book.entries[12].enabled, isFalse);
    expect(result.book.entries[13].enabled, isFalse);
    expect(result.book.entries[14].enabled, isFalse);
    expect(
      result.warnings,
      contains('Unsupported world-book conditions were disabled.'),
    );
  });

  group('character-card timing conditions', () {
    final cases = <({String name, Map<String, dynamic> fields, bool enabled})>[
      (
        name: 'top-level zero values',
        fields: {'sticky': 0, 'cooldown': 0, 'delay': 0},
        enabled: true,
      ),
      (
        name: 'top-level sticky',
        fields: {'sticky': 2, 'cooldown': 0, 'delay': 0},
        enabled: false,
      ),
      (
        name: 'top-level cooldown after zero sticky',
        fields: {'sticky': 0, 'cooldown': 5, 'delay': 0},
        enabled: false,
      ),
      (
        name: 'top-level delay after zero sticky and cooldown',
        fields: {'sticky': 0, 'cooldown': 0, 'delay': 1},
        enabled: false,
      ),
      (name: 'missing timing fields', fields: const {}, enabled: true),
      (
        name: 'extension zero values',
        fields: {
          'extensions': {'sticky': 0, 'cooldown': 0, 'delay': 0},
        },
        enabled: true,
      ),
      (
        name: 'extension cooldown after zero sticky',
        fields: {
          'extensions': {'sticky': 0, 'cooldown': 5},
        },
        enabled: false,
      ),
      (
        name: 'extension delay after zero sticky',
        fields: {
          'extensions': {'sticky': 0, 'delay': 1},
        },
        enabled: false,
      ),
    ];

    for (final scenario in cases) {
      test(scenario.name, () {
        final result = WorldBookImportService.parse({
          'name': 'Timing book',
          'entries': [
            {
              'key': ['lantern'],
              'comment': 'Timing entry',
              'content': 'The lantern is warm.',
              'enabled': true,
              'order': 17,
              'position': 1,
              'role': 0,
              ...scenario.fields,
            },
          ],
        }, policy: WorldBookImportPolicy.characterCard);

        expect(result, isNotNull);
        final parsed = result!;
        expect(parsed.skippedEntries, 0);
        expect(parsed.book.entries, hasLength(1));
        final entry = parsed.book.entries.single;
        expect(entry.enabled, scenario.enabled);
        expect(entry.keywords, ['lantern']);
        expect(entry.content, 'The lantern is warm.');
        expect(entry.priority, 17);
        expect(entry.position, WorldBookInjectionPosition.afterSystemPrompt);
        expect(entry.role, WorldBookInjectionRole.user);

        expect(parsed.hasUnsupportedSettings, !scenario.enabled);
        if (!scenario.enabled) {
          expect(
            parsed.warnings,
            contains('Unsupported world-book conditions were disabled.'),
          );
        }
      });
    }
  });

  test(
    'character_book conversion is conservative and binds a new book',
    () async {
      final parsed = CharacterCardImportService.parseJsonString(
        jsonEncode({
          'name': 'Mira',
          'character_book': {
            'name': 'Mira Lore',
            'entries': [
              {
                'comment': 'Harbor',
                'keys': ['harbor'],
                'content': 'The harbor is closed.',
                'enabled': true,
              },
              {
                'comment': 'Regex only',
                'keys': ['/secret/i'],
                'content': 'Do not activate broadly.',
                'enabled': true,
              },
              {
                'comment': 'Mixed',
                'keys': ['harbor', '/danger/'],
                'content': 'Keep only the ordinary keyword.',
                'enabled': true,
              },
              {
                'comment': 'Secondary',
                'keys': ['castle'],
                'keysecondary': ['red'],
                'content': 'Requires unsupported AND matching.',
                'enabled': true,
              },
              'malformed',
            ],
          },
        }),
      );

      expect(parsed.totalWorldBookEntries, 5);
      expect(parsed.enabledWorldBookEntries, 2);
      expect(parsed.disabledWorldBookEntries, 2);
      expect(parsed.skippedWorldBookEntries, 1);
      expect(parsed.embeddedWorldBook!.warnings, isNotEmpty);

      final harness = await createBusinessTestHarness();
      final assistants = AssistantProvider(preferences: harness.preferences);
      final books = WorldBookProvider(preferences: harness.preferences);
      final committed = await CharacterCardImportCoordinator(
        assistantProvider: assistants,
        worldBookProvider: books,
      ).commit(parsed);

      expect(committed.assistant.mode.name, 'roleplay');
      expect(committed.worldBook, isNotNull);
      final book = books.books.single;
      expect(book.id, isNot('Mira Lore'));
      expect(book.entries.map((entry) => entry.id).toSet(), hasLength(4));
      expect(books.activeBookIdsFor(committed.assistant.id), contains(book.id));
      expect(book.entries[0].keywords, ['harbor']);
      expect(book.entries[0].enabled, isTrue);
      expect(book.entries[1].keywords, isEmpty);
      expect(book.entries[1].enabled, isFalse);
      expect(book.entries[2].keywords, ['harbor']);
      expect(book.entries[2].useRegex, isFalse);
      expect(book.entries[2].enabled, isTrue);
      expect(book.entries[3].enabled, isFalse);
    },
  );

  test('cards without an embedded book do not create an empty book', () async {
    final parsed = CharacterCardImportService.parseJsonString(
      jsonEncode({'name': 'No Lore', 'description': 'plain'}),
    );
    final harness = await createBusinessTestHarness();
    final assistants = AssistantProvider(preferences: harness.preferences);
    final books = WorldBookProvider(preferences: harness.preferences);

    final committed = await CharacterCardImportCoordinator(
      assistantProvider: assistants,
      worldBookProvider: books,
    ).commit(parsed);

    expect(committed.worldBook, isNull);
    expect(books.books, isEmpty);
    expect(books.activeBookIdsFor(committed.assistant.id), isEmpty);
  });
}
