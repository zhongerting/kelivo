import 'dart:convert';
import 'dart:io';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_models.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_pipeline.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_repository.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_source.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late BusinessRepository businessRepository;
  late BusinessPreferences preferences;
  late ChatDatabaseRepository chatRepository;
  late ChatService chatService;
  late SettingsProvider settings;
  late AssistantProvider assistants;
  late StoryMemoryRepository repository;
  late StoryMemoryPipelineService pipeline;
  late Directory tempDirectory;
  late PathProviderPlatform previousPathProvider;
  String? nextResponse;
  Object? generatorError;
  var generatorCalls = 0;
  var lastPrompt = '';
  String? lastConversationId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDirectory = await Directory.systemTemp.createTemp(
      'kelivo_story_memory_pipeline_',
    );
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(tempDirectory.path);

    database = AppDatabase(NativeDatabase.memory());
    businessRepository = BusinessRepository(database);
    preferences = BusinessPreferences(businessRepository);
    chatRepository = ChatDatabaseRepository(database);
    await chatRepository.ensureReady();
    await preferences.load();

    chatService = ChatService(existingRepository: chatRepository);
    await chatService.init();

    settings = SettingsProvider(preferences);
    await settings.loaded;
    await settings.setMemoryModel('openai', 'gpt-test');
    final config = settings.getProviderConfig('openai');
    await settings.setProviderConfig(
      'openai',
      config.copyWith(models: ['gpt-test']),
    );

    assistants = AssistantProvider(
      preferences: preferences,
      chatService: chatService,
    );
    await assistants.loaded;
    await assistants.addAssistantObject(_storyAssistant());

    repository = StoryMemoryRepository(businessRepository: businessRepository);
    nextResponse = null;
    generatorError = null;
    generatorCalls = 0;
    lastPrompt = '';
    lastConversationId = null;
    pipeline = StoryMemoryPipelineService(
      chatService: chatService,
      repository: repository,
      settings: () => settings,
      assistants: () => assistants,
      generateText:
          ({
            required ProviderConfig config,
            required String modelId,
            required String prompt,
            String? conversationId,
            int? thinkingBudget,
          }) async {
            generatorCalls++;
            lastPrompt = prompt;
            lastConversationId = conversationId;
            final error = generatorError;
            if (error != null) throw error;
            return nextResponse ?? '';
          },
    );
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    await chatService.close();
    await database.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test(
    'manual organize commits a strict patch and advances coverage',
    () async {
      final conversation = await _seedConversation(chatService, count: 4);
      final source = await StoryMemorySource.load(chatService, conversation.id);
      nextResponse = _patchJson(
        conversation.id,
        source,
        'summary-1',
        operations: [
          {
            'op': 'upsertCharacter',
            'characterId': 'char-1',
            'fields': {'name': 'Mara', 'identity': 'A careful scout'},
          },
        ],
      );

      final result = await pipeline.runNow(
        conversationId: conversation.id,
        assistantId: 'assistant-1',
      );

      expect(result.advanced, isTrue);
      expect(result.error, isNull);
      expect(result.operationCount, 2);
      expect(generatorCalls, 1);
      expect(lastConversationId, conversation.id);
      expect(lastPrompt, contains('message 0'));
      final snapshot = await repository.read(conversation.id);
      expect(snapshot.rowsFor(StoryMemoryTable.character), hasLength(1));
      expect(snapshot.rowsFor(StoryMemoryTable.plotSummary), hasLength(1));
      expect(snapshot.checkpoints.single.endOrder, 3);
    },
  );

  test('automatic organize below threshold does not call the model', () async {
    final conversation = await _seedConversation(chatService, count: 2);

    pipeline.scheduleIfNeeded(
      conversationId: conversation.id,
      assistantId: 'assistant-1',
    );
    await _waitUntil(() => pipeline.lastStatus.lastResult != null);

    expect(pipeline.lastStatus.lastResult?.error, 'story_below_threshold');
    expect(generatorCalls, 0);
    expect((await repository.read(conversation.id)).checkpoints, isEmpty);
  });

  test('model failure leaves coverage untouched', () async {
    final conversation = await _seedConversation(chatService, count: 2);
    generatorError = StateError('network_down');

    final result = await pipeline.runNow(
      conversationId: conversation.id,
      assistantId: 'assistant-1',
    );

    expect(result.advanced, isFalse);
    expect(result.error, contains('network_down'));
    expect((await repository.read(conversation.id)).checkpoints, isEmpty);
  });

  test(
    'incomplete source text does not call the memory model or advance coverage',
    () async {
      final conversation = await chatService.createConversation(
        title: 'Long story',
        assistantId: 'assistant-1',
      );
      await chatService.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: List.filled(4001, 'x').join(),
      );
      await chatService.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        content: 'A short response',
      );

      final result = await pipeline.runNow(
        conversationId: conversation.id,
        assistantId: 'assistant-1',
      );

      expect(result.advanced, isFalse);
      expect(result.error, 'story_source_text_incomplete');
      expect(generatorCalls, 0);
      expect((await repository.read(conversation.id)).checkpoints, isEmpty);
    },
  );

  test('malformed and mismatched model patches fail open', () async {
    final conversation = await _seedConversation(chatService, count: 2);
    final source = await StoryMemorySource.load(chatService, conversation.id);

    nextResponse = '{"not":"a story patch"}';
    final malformed = await pipeline.runNow(
      conversationId: conversation.id,
      assistantId: 'assistant-1',
    );
    expect(malformed.advanced, isFalse);
    expect(malformed.error, contains('story_patch'));
    expect((await repository.read(conversation.id)).checkpoints, isEmpty);

    nextResponse = _patchJson(
      conversation.id,
      source,
      'summary-mismatch',
      sourceDigest: 'b' * 64,
    );
    final mismatched = await pipeline.runNow(
      conversationId: conversation.id,
      assistantId: 'assistant-1',
    );
    expect(mismatched.advanced, isFalse);
    expect(mismatched.error, 'story_patch_source_mismatch');
    expect((await repository.read(conversation.id)).checkpoints, isEmpty);
  });

  test(
    'confirmation mode persists one pending patch and deduplicates retries',
    () async {
      await assistants.updateAssistant(
        assistants
            .getById('assistant-1')!
            .copyWith(storyMemoryRequireConfirmation: true),
      );
      final conversation = await _seedConversation(chatService, count: 4);
      final source = await StoryMemorySource.load(chatService, conversation.id);
      nextResponse = _patchJson(conversation.id, source, 'summary-confirm');

      final first = await pipeline.runNow(
        conversationId: conversation.id,
        assistantId: 'assistant-1',
      );
      final second = await pipeline.runNow(
        conversationId: conversation.id,
        assistantId: 'assistant-1',
      );

      expect(first.error, 'confirmation_required');
      expect(first.pendingPatchId, isNotNull);
      expect(second.error, 'confirmation_required');
      expect(second.pendingPatchId, first.pendingPatchId);
      expect(generatorCalls, 1);
      expect((await repository.read(conversation.id)).checkpoints, isEmpty);

      await repository.confirmPendingPatch(
        pendingId: first.pendingPatchId!,
        source: source,
      );
      expect(
        (await repository.read(conversation.id)).checkpoints.single.endOrder,
        3,
      );
    },
  );

  test(
    'stale coverage is rebuilt immediately without stale merge fields',
    () async {
      final conversation = await _seedConversation(chatService, count: 2);
      final source = await StoryMemorySource.load(chatService, conversation.id);
      nextResponse = _patchJson(
        conversation.id,
        source,
        'summary-old',
        operations: [
          {
            'op': 'upsertCharacter',
            'characterId': 'char-1',
            'fields': {'name': 'Mara', 'identity': 'Old identity'},
          },
        ],
      );
      expect(
        (await pipeline.runNow(
          conversationId: conversation.id,
          assistantId: 'assistant-1',
        )).advanced,
        isTrue,
      );

      await repository.markStaleFromOrder(
        conversationId: conversation.id,
        order: 0,
      );
      nextResponse = _patchJson(
        conversation.id,
        source,
        'summary-rebuilt',
        operations: [
          {
            'op': 'upsertCharacter',
            'characterId': 'char-1',
            'fields': {'name': 'Mara'},
          },
        ],
      );

      final result = await pipeline.runNow(
        conversationId: conversation.id,
        assistantId: 'assistant-1',
      );
      final character = (await repository.read(
        conversation.id,
      )).rowById(StoryMemoryTable.character, 'char-1')!;

      expect(result.advanced, isTrue);
      expect(lastPrompt, isNot(contains('Old identity')));
      expect(character.data, isNot(contains('identity')));
      expect(character.data['sourcePatchId'], isNotNull);
      expect(
        (await repository.inspectCoverage(
          conversation.id,
          source,
        )).coveredEndOrder,
        1,
      );
    },
  );
}

Assistant _storyAssistant() => const Assistant(
  id: 'assistant-1',
  name: 'Story assistant',
  enableStoryMemory: true,
  autoOrganizeStoryMemory: true,
  storyMemoryOrganizeEveryNTurns: 4,
);

Future<Conversation> _seedConversation(
  ChatService chatService, {
  required int count,
}) async {
  final conversation = await chatService.createConversation(
    title: 'Story',
    assistantId: 'assistant-1',
  );
  for (var index = 0; index < count; index++) {
    await chatService.addMessage(
      conversationId: conversation.id,
      role: index.isEven ? 'user' : 'assistant',
      content: 'message $index',
    );
  }
  return conversation;
}

String _patchJson(
  String conversationId,
  List<StoryMemorySourceItem> source,
  String summaryId, {
  List<Map<String, dynamic>> operations = const [],
  String? sourceDigest,
}) {
  final digest = sourceDigest ?? StoryMemorySource.digest(source);
  return jsonEncode({
    'schemaVersion': 1,
    'conversationId': conversationId,
    'sourceStartOrder': source.first.order,
    'sourceEndOrder': source.last.order,
    'sourceDigest': digest,
    'operations': [
      ...operations,
      {
        'op': 'appendPlotSummary',
        'row': {
          'summaryId': summaryId,
          'sourceStartOrder': source.first.order,
          'sourceEndOrder': source.last.order,
          'sourceDigest': digest,
          'sourceMessageIds': [for (final item in source) item.message.id],
          'summary': 'A faithful summary',
          'keyEntities': <String>[],
          'unresolvedThreads': <String>[],
        },
      },
    ],
  });
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100 && !predicate(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue);
}

final class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.path);

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
