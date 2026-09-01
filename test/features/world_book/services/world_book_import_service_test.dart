import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/world_book.dart';
import 'package:Kelivo/features/world_book/services/world_book_import_service.dart';

void main() {
  group('WorldBookImportService', () {
    test('imports the bundled minimal SillyTavern sample', () {
      final sample = jsonDecode(
        File('samples/sillytavern-minimal-world-book.json').readAsStringSync(),
      );
      final result = WorldBookImportService.parse(
        sample,
        fallbackName: 'sillytavern-minimal-world-book',
      );

      expect(result, isNotNull);
      expect(result!.format, WorldBookImportFormat.sillyTavern);
      expect(result.hasUnsupportedSettings, isFalse);
      expect(result.book.entries, hasLength(1));
      expect(result.book.entries.single.name, '蓝港城');
      expect(result.book.entries.single.keywords, ['蓝港城']);
      expect(result.book.entries.single.content, '蓝港城是一座临海小城，城中心有一座白色灯塔。');
    });

    test('keeps the existing Kelivo/RikkaHub format unchanged', () {
      final result = WorldBookImportService.parse({
        'version': 1,
        'type': 'lorebook',
        'data': {
          'id': 'book-1',
          'name': 'Kelivo book',
          'entries': [
            {
              'id': 'entry-1',
              'name': 'Capital',
              'keywords': ['capital'],
              'content': 'The capital is here.',
              'position': 'AFTER_SYSTEM_PROMPT',
              'constantActive': false,
            },
          ],
        },
      });

      expect(result, isNotNull);
      expect(result!.format, WorldBookImportFormat.kelivo);
      expect(result.book.id, 'book-1');
      expect(result.book.name, 'Kelivo book');
      expect(result.book.entries.single.id, 'entry-1');
      expect(result.book.entries.single.keywords, ['capital']);
    });

    test('converts a native SillyTavern world info export', () {
      final result = WorldBookImportService.parse({
        'entries': {
          '7': {
            'uid': 7,
            'comment': 'Dragons',
            'key': ['a+b', '/wyrms?/i'],
            'keysecondary': ['red'],
            'content': 'Dragons live in the northern mountains.',
            'constant': true,
            'disable': false,
            'order': 250,
            'position': 4,
            'depth': 3,
            'role': 2,
            'scanDepth': 6,
            'caseSensitive': true,
          },
        },
      }, fallbackName: 'fantasy-lore');

      expect(result, isNotNull);
      expect(result!.format, WorldBookImportFormat.sillyTavern);
      expect(result.book.name, 'fantasy-lore');
      expect(result.hasUnsupportedSettings, isTrue);
      expect(result.skippedEntries, 0);

      final entry = result.book.entries.single;
      expect(entry.id, '7');
      expect(entry.name, 'Dragons');
      expect(entry.enabled, isTrue);
      expect(entry.priority, 250);
      expect(entry.position, WorldBookInjectionPosition.atDepth);
      expect(entry.injectDepth, 3);
      expect(entry.role, WorldBookInjectionRole.assistant);
      expect(entry.scanDepth, 6);
      expect(entry.constantActive, isTrue);
      expect(entry.useRegex, isTrue);
      expect(entry.caseSensitive, isFalse);
      expect(entry.keywords, [r'a\+b', r'wyrms?']);
    });

    test('converts a character_book array and nested extension fields', () {
      final result = WorldBookImportService.parse({
        'name': 'Character lore',
        'description': 'Lore exported with a character card',
        'scan_depth': 8,
        'entries': [
          {
            'id': 12,
            'name': 'Royal capital',
            'keys': ['王都'],
            'content': '王都是这个国家的首都。',
            'enabled': false,
            'constant': false,
            'insertion_order': 120,
            'position': 'before_char',
            'extensions': {'position': 0, 'case_sensitive': true, 'depth': 2},
          },
        ],
      });

      expect(result, isNotNull);
      expect(result!.format, WorldBookImportFormat.sillyTavern);
      expect(result.book.name, 'Character lore');
      expect(result.book.description, 'Lore exported with a character card');

      final entry = result.book.entries.single;
      expect(entry.id, '12');
      expect(entry.name, 'Royal capital');
      expect(entry.keywords, ['王都']);
      expect(entry.enabled, isFalse);
      expect(entry.priority, 120);
      expect(entry.position, WorldBookInjectionPosition.beforeSystemPrompt);
      expect(entry.caseSensitive, isTrue);
      expect(entry.scanDepth, 8);
    });

    test('finds character_book inside a full character card', () {
      final result = WorldBookImportService.parse({
        'spec': 'chara_card_v3',
        'data': {
          'name': 'Character',
          'character_book': {
            'name': 'Embedded lore',
            'entries': [
              {
                'id': 1,
                'keys': ['harbor'],
                'content': 'The harbor is closed at night.',
                'enabled': true,
              },
            ],
          },
        },
      });

      expect(result, isNotNull);
      expect(result!.format, WorldBookImportFormat.sillyTavern);
      expect(result.book.name, 'Embedded lore');
      expect(result.book.entries.single.keywords, ['harbor']);
    });

    test('skips malformed SillyTavern entries without rejecting the book', () {
      final result = WorldBookImportService.parse({
        'entries': {
          '0': 'not an entry',
          '1': {
            'uid': 1,
            'key': ['valid'],
            'content': 'Valid content',
          },
        },
      });

      expect(result, isNotNull);
      expect(result!.skippedEntries, 1);
      expect(result.book.entries, hasLength(1));
    });

    test('rejects unrelated JSON', () {
      expect(WorldBookImportService.parse({'hello': 'world'}), isNull);
      expect(WorldBookImportService.parse(['not', 'a', 'book']), isNull);
    });
  });
}
