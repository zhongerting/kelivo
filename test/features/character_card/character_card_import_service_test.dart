import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/features/character_card/models/character_card_import_result.dart';
import 'package:Kelivo/features/character_card/services/character_card_import_service.dart';

void main() {
  group('CharacterCardImportService JSON', () {
    test('imports V1 fields and reports executable or unsupported fields', () {
      final result = CharacterCardImportService.parseJsonString(
        jsonEncode({
          'name': 'Mira',
          'description': 'desc {{char}} {{unknown}}',
          'personality': 'kind',
          'scenario': 'station',
          'first_mes': 'Hello {{user}}.',
          'system_prompt': 'must never be imported',
          'post_history_instructions': 'also ignored',
          'mes_example': '<START> ignored',
          'alternate_greetings': ['ignored'],
          'extensions': {
            'depth_prompt': {'prompt': 'ignored'},
            'regex_scripts': [
              {'findRegex': '.*', 'replaceString': 'danger'},
            ],
            'tavern_helper': {
              'scripts': ['ignored'],
            },
          },
          'temperature': 0.2,
        }),
      );

      expect(result.sourceFormat, CharacterCardSourceFormat.jsonV1);
      expect(result.assistantDraft.name, 'Mira');
      expect(
        result.assistantDraft.characterPrompt,
        contains('<character_description>'),
      );
      expect(
        result.assistantDraft.characterPrompt,
        contains('desc {{char}} {{unknown}}'),
      );
      expect(
        result.assistantDraft.characterPrompt,
        contains('<character_personality>'),
      );
      expect(
        result.assistantDraft.characterPrompt,
        contains('<character_scenario>'),
      );
      expect(result.assistantDraft.firstMessage, 'Hello {{user}}.');
      expect(result.ignoredFields, contains('system_prompt'));
      expect(result.ignoredFields, contains('post_history_instructions'));
      expect(result.ignoredFields, contains('mes_example'));
      expect(result.ignoredFields, contains('alternate_greetings'));
      expect(result.ignoredFields, contains('extensions.regex_scripts'));
      expect(result.ignoredFields, contains('extensions.tavern_helper'));
      expect(result.ignoredFields, contains('temperature'));
      expect(result.ignoredFieldCounts['extensions.regex_scripts'], 1);
      expect(result.ignoredFieldCounts['extensions.tavern_helper'], 1);
      expect(result.ignoredFieldCounts['temperature'], 1);
      expect(
        result.assistantDraft.characterPrompt,
        isNot(contains('must never be imported')),
      );
      expect(result.assistantDraft.characterPrompt, isNot(contains('danger')));
    });

    test('reads V2 and V3 fields from data and keeps source version', () {
      final v2 = CharacterCardImportService.parseJsonString(
        jsonEncode({
          'spec': 'chara_card_v2',
          'spec_version': '2.0',
          'name': 'root name',
          'data': {
            'name': 'V2 name',
            'description': 'V2 description',
            'first_mes': 'V2 greeting',
          },
        }),
      );
      final v3 = CharacterCardImportService.parseJsonString(
        jsonEncode({
          'spec': 'chara_card_v3',
          'spec_version': '3.0',
          'data': {'name': 'V3 name', 'scenario': 'V3 scenario'},
        }),
      );

      expect(v2.sourceFormat, CharacterCardSourceFormat.jsonV2);
      expect(v2.specVersion, '2.0');
      expect(v2.assistantDraft.name, 'V2 name');
      expect(v2.assistantDraft.firstMessage, 'V2 greeting');
      expect(v3.sourceFormat, CharacterCardSourceFormat.jsonV3);
      expect(v3.specVersion, '3.0');
      expect(v3.assistantDraft.name, 'V3 name');
      expect(v3.assistantDraft.characterPrompt, contains('V3 scenario'));
    });

    test('uses filename when name is absent and preserves unknown macros', () {
      final result = CharacterCardImportService.parseJsonString(
        '{"description":"Use {{user}} and {{unknown::x}}"}',
        fallbackName: 'Fallback',
        sourceFileName: 'card.json',
      );

      expect(result.assistantDraft.name, 'Fallback');
      expect(result.assistantDraft.characterPrompt, contains('{{unknown::x}}'));
    });
  });

  group('CharacterCardImportService PNG', () {
    test('prefers ccv3 over chara and copies the PNG as avatar bytes', () {
      final oldCard = jsonEncode({'name': 'V1', 'description': 'old'});
      final newCard = jsonEncode({
        'spec': 'chara_card_v3',
        'spec_version': '3.0',
        'data': {'name': 'V3', 'description': 'new'},
      });
      final png = _pngWithText([
        ('chara', base64Encode(utf8.encode(oldCard))),
        ('ccv3', base64Encode(utf8.encode(newCard))),
      ]);

      final result = CharacterCardImportService.parsePngBytes(
        png,
        fallbackName: 'fallback',
        sourceFileName: 'mira.png',
      );

      expect(result.sourceFormat, CharacterCardSourceFormat.png);
      expect(result.specVersion, '3.0');
      expect(result.assistantDraft.name, 'V3');
      expect(result.assistantDraft.avatarBytes, orderedEquals(png));
      expect(result.sourceFileName, 'mira.png');
    });

    test('accepts iTXt and compressed iTXt metadata', () {
      final card = jsonEncode({'name': 'International', 'first_mes': 'Hi'});
      final encoded = base64Encode(utf8.encode(card));
      final png = _pngWithChunks([_chunk('iTXt', _iTxt('chara', encoded))]);
      final compressed = _pngWithChunks([
        _chunk('iTXt', _iTxt('chara', encoded, compressed: true)),
      ]);

      expect(
        CharacterCardImportService.parsePngBytes(png).assistantDraft.name,
        'International',
      );
      expect(
        CharacterCardImportService.parsePngBytes(
          compressed,
        ).assistantDraft.name,
        'International',
      );
    });

    test('accepts legal unpadded Base64 metadata', () {
      final card = jsonEncode({'name': 'Unpadded'});
      final encoded = base64Encode(utf8.encode(card)).replaceAll('=', '');
      final result = CharacterCardImportService.parsePngBytes(
        _pngWithText([('chara', encoded)]),
      );

      expect(result.assistantDraft.name, 'Unpadded');
    });

    test('rejects non-card PNG and malformed metadata', () {
      expect(
        () => CharacterCardImportService.parsePngBytes(
          _pngWithText([('chara', 'not-base64')]),
        ),
        throwsA(isA<CharacterCardImportException>()),
      );
      expect(
        () => CharacterCardImportService.parsePngBytes(
          _pngWithText([
            ('chara', base64Encode([0xff])),
          ]),
        ),
        throwsA(isA<CharacterCardImportException>()),
      );
      expect(
        () => CharacterCardImportService.parsePngBytes(_pngWithChunks([])),
        throwsA(isA<CharacterCardImportException>()),
      );
      expect(
        () => CharacterCardImportService.parsePngBytes(
          _pngWithChunks([
            _chunk(
              'tEXt',
              Uint8List(CharacterCardImportService.maxPngMetadataBytes + 1),
            ),
          ]),
        ),
        throwsA(isA<CharacterCardImportException>()),
      );
      expect(
        () => CharacterCardImportService.parsePngBytes(
          _pngWithChunks([
            _chunkWithType([0xff, 0, 0, 0], Uint8List(0)),
          ]),
        ),
        throwsA(isA<CharacterCardImportException>()),
      );
    });

    test('accepts a controlled PNG with an IDAT chunk larger than 2 MiB', () {
      final card = jsonEncode({'name': 'Large Image'});
      final metadata = Uint8List.fromList([
        ...ascii.encode('chara'),
        0,
        ...ascii.encode(base64Encode(utf8.encode(card))),
      ]);
      final png = _pngWithChunks([
        _chunk('IDAT', Uint8List(2 * 1024 * 1024 + 1)),
        _chunk('tEXt', metadata),
      ]);

      final result = CharacterCardImportService.parsePngBytes(png);

      expect(result.assistantDraft.name, 'Large Image');
      expect(result.assistantDraft.avatarBytes, orderedEquals(png));
    });

    test('keeps total-size, truncation, and IEND protections', () {
      expect(
        () => CharacterCardImportService.parsePngBytes(
          _pngWithChunks([
            _chunk('IDAT', Uint8List(CharacterCardImportService.maxPngBytes)),
          ]),
        ),
        throwsA(isA<CharacterCardImportException>()),
      );
      expect(
        () => CharacterCardImportService.parsePngBytes(
          _pngWithChunks([_truncatedChunk('IDAT', declaredLength: 5)]),
        ),
        throwsA(isA<CharacterCardImportException>()),
      );
      expect(
        () => CharacterCardImportService.parsePngBytes(
          _pngWithoutIend([_chunk('IDAT', Uint8List(0))]),
        ),
        throwsA(isA<CharacterCardImportException>()),
      );
    });

    test('rejects compressed metadata whose expanded output is too large', () {
      final oversized = base64Encode(
        List<int>.filled(
          CharacterCardImportService.maxPngMetadataBytes + 1,
          65,
        ),
      );
      final compressed = _pngWithChunks([
        _chunk('iTXt', _iTxt('chara', oversized, compressed: true)),
      ]);

      expect(
        () => CharacterCardImportService.parsePngBytes(compressed),
        throwsA(isA<CharacterCardImportException>()),
      );
    });

    test('reports every world-book entry over the safety limit', () {
      final result = CharacterCardImportService.parseJsonString(
        jsonEncode({
          'name': 'Large Book',
          'character_book': {
            'entries': [
              for (
                var i = 0;
                i < CharacterCardImportService.maxWorldBookEntries + 2;
                i++
              )
                {
                  'keys': ['key-$i'],
                  'content': 'entry-$i',
                },
            ],
          },
        }),
      );

      expect(result.embeddedWorldBook!.entries, hasLength(10000));
      expect(result.skippedWorldBookEntries, 2);
      expect(result.totalWorldBookEntries, 10002);
    });
  });

  test('draft creates an RP assistant without merging into systemPrompt', () {
    const draft = CharacterCardAssistantDraft(
      name: 'Mira',
      characterPrompt: '<character_description>desc</character_description>',
      firstMessage: 'hello',
    );
    final assistant = draft.toAssistant(id: 'assistant-id');

    expect(assistant.mode, AssistantMode.roleplay);
    expect(assistant.systemPrompt, isEmpty);
    expect(assistant.characterPrompt, contains('desc'));
    expect(assistant.firstMessage, 'hello');
    expect(assistant.excludeThinkingFromContext, isTrue);
  });
}

Uint8List _pngWithText(List<(String key, String value)> items) {
  return _pngWithChunks([
    for (final item in items)
      _chunk(
        'tEXt',
        Uint8List.fromList([
          ...ascii.encode(item.$1),
          0,
          ...ascii.encode(item.$2),
        ]),
      ),
  ]);
}

Uint8List _pngWithChunks(List<Uint8List> chunks) {
  final bytes = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  bytes.addAll(_chunk('IHDR', Uint8List(13)));
  for (final chunk in chunks) {
    bytes.addAll(chunk);
  }
  bytes.addAll(_chunk('IEND', Uint8List(0)));
  return Uint8List.fromList(bytes);
}

Uint8List _pngWithoutIend(List<Uint8List> chunks) {
  final bytes = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  bytes.addAll(_chunk('IHDR', Uint8List(13)));
  for (final chunk in chunks) {
    bytes.addAll(chunk);
  }
  return Uint8List.fromList(bytes);
}

Uint8List _chunk(String type, List<int> data) {
  final bytes = <int>[];
  bytes.addAll(_u32(data.length));
  bytes.addAll(ascii.encode(type));
  bytes.addAll(data);
  bytes.addAll([0, 0, 0, 0]);
  return Uint8List.fromList(bytes);
}

List<int> _u32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

Uint8List _chunkWithType(List<int> type, List<int> data) =>
    Uint8List.fromList([..._u32(data.length), ...type, ...data, 0, 0, 0, 0]);

Uint8List _truncatedChunk(String type, {required int declaredLength}) =>
    Uint8List.fromList([..._u32(declaredLength), ...ascii.encode(type), 0]);

List<int> _iTxt(String key, String value, {bool compressed = false}) {
  final text = compressed
      ? ZLibCodec().encode(utf8.encode(value))
      : utf8.encode(value);
  return [...ascii.encode(key), 0, compressed ? 1 : 0, 0, 0, 0, ...text];
}
