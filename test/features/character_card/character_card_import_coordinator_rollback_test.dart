import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/world_book_provider.dart';
import 'package:Kelivo/features/character_card/models/character_card_import_result.dart';
import 'package:Kelivo/features/character_card/services/character_card_import_coordinator.dart';
import 'package:Kelivo/features/character_card/services/character_card_import_service.dart';
import 'package:Kelivo/utils/app_directories.dart';

import '../../support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDirectory;
  late PathProviderPlatform previousPathProvider;
  setUpAll(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kelivo_character_card_rollback_test_',
    );
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(
      tempDirectory.path,
    );
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  for (final failure in _ImportFailure.values) {
    test(
      'rolls back ${failure.name} failures without half-finished data',
      () async {
        final original = const Assistant(id: 'original', name: 'Original');
        final injector = _FailOnce(failure.key);
        final harness = await createBusinessTestHarness(
          initial: <String, Object?>{
            'assistants_v1': Assistant.encodeList(<Assistant>[original]),
            'current_assistant_id_v1': original.id,
          },
          writeInterceptor: injector.call,
        );
        final assistants = AssistantProvider(preferences: harness.preferences);
        final books = WorldBookProvider(preferences: harness.preferences);
        await assistants.loaded;
        await books.initialize();
        final beforeAvatars = await _avatarPaths();

        await expectLater(
          CharacterCardImportCoordinator(
            assistantProvider: assistants,
            worldBookProvider: books,
          ).commit(_parsedCard()),
          throwsA(isA<CharacterCardImportException>()),
        );

        expect(injector.didFail, isTrue);
        expect(assistants.assistants, hasLength(1));
        expect(assistants.assistants.single.toJson(), original.toJson());
        expect(assistants.currentAssistantId, original.id);
        expect(books.books, isEmpty);
        expect(books.activeBookIdsFor(original.id), isEmpty);
        expect(
          harness.preferences.getString('assistants_v1'),
          Assistant.encodeList(<Assistant>[original]),
        );
        expect(
          harness.preferences.getString('current_assistant_id_v1'),
          'original',
        );
        final storedBooks = harness.preferences.getString('world_books_v1');
        expect(
          storedBooks == null ? const <dynamic>[] : jsonDecode(storedBooks),
          isEmpty,
        );
        expect(
          harness.preferences.getString(
            'world_books_active_ids_by_assistant_v1',
          ),
          isNull,
        );
        expect(await _avatarPaths(), beforeAvatars);
      },
    );
  }
}

final class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

enum _ImportFailure {
  assistantList(key: 'assistants_v1'),
  currentAssistant(key: 'current_assistant_id_v1'),
  worldBook(key: 'world_books_v1'),
  worldBookBinding(key: 'world_books_active_ids_by_assistant_v1');

  const _ImportFailure({required this.key});

  final String key;
}

final class _FailOnce {
  _FailOnce(this.key);

  final String key;
  bool didFail = false;

  void call(String actualKey, Object? value) {
    if (!didFail && actualKey == key) {
      didFail = true;
      throw StateError('injected_failure:$key');
    }
  }
}

CharacterCardImportResult _parsedCard() {
  final result = CharacterCardImportService.parseJsonString(
    jsonEncode(<String, dynamic>{
      'name': 'Imported',
      'description': 'A safe description.',
      'first_mes': 'Hello.',
      'character_book': <String, dynamic>{
        'name': 'Imported Lore',
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{
            'keys': <String>['harbor'],
            'content': 'The harbor is closed.',
            'enabled': true,
          },
        ],
      },
    }),
  );
  return result.copyWith(
    assistantDraft: CharacterCardAssistantDraft(
      name: result.assistantDraft.name,
      characterPrompt: result.assistantDraft.characterPrompt,
      firstMessage: result.assistantDraft.firstMessage,
      avatarBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
    ),
  );
}

Future<Set<String>> _avatarPaths() async {
  final directory = await AppDirectories.getAvatarsDirectory();
  if (!await directory.exists()) return <String>{};
  return (await directory.list().toList())
      .whereType<File>()
      .map((file) => file.path)
      .toSet();
}
