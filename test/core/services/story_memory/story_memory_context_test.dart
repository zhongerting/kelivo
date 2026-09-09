import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_data.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_context.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_models.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_repository.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  late BusinessRepository businessRepository;
  late StoryMemoryRepository storyRepository;
  late ChatService chatService;
  late Directory tempDirectory;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kelivo_story_memory_context_',
    );
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(tempDirectory.path);
    database = AppDatabase(NativeDatabase.memory());
    businessRepository = BusinessRepository(database);
    storyRepository = StoryMemoryRepository(
      businessRepository: businessRepository,
    );
    final chatRepository = ChatDatabaseRepository(database);
    await chatRepository.ensureReady();
    chatService = ChatService(existingRepository: chatRepository);
    await chatService.init();
  });

  tearDown(() async {
    await chatService.close();
    await database.close();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('complete verified coverage replaces only the request copy', () async {
    final conversation = await _seedConversation(chatService, count: 4);
    final source = await StoryMemorySource.load(chatService, conversation.id);
    final covered = source.sublist(0, 2);
    await storyRepository.applyPatch(
      patch: _summaryPatch(conversation.id, covered, 'summary-1'),
      source: covered,
    );

    final original = List<ChatMessage>.of(
      await chatService.loadMessages(conversation.id),
    );
    final result =
        await StoryMemoryContextBuilder(
          repository: storyRepository,
          chatService: chatService,
        ).prepare(
          messages: original,
          conversation: conversation,
          assistant: const Assistant(
            id: 'assistant-1',
            name: 'Story assistant',
            enableStoryMemory: true,
            storyMemoryRecentTurnRetention: 1,
          ),
        );

    expect(result.replacedHistory, isTrue);
    expect(result.messages, hasLength(2));
    expect(result.injection, contains('<story_memory>'));
    expect(original, hasLength(4));
    expect(result.messages.map((message) => message.id), isNotEmpty);
  });

  test(
    'a coverage hole keeps full history and disables memory injection',
    () async {
      final conversation = await _seedConversation(chatService, count: 4);
      final source = await StoryMemorySource.load(chatService, conversation.id);
      final covered = source.sublist(0, 2);
      await storyRepository.applyPatch(
        patch: _summaryPatch(conversation.id, covered, 'summary-1'),
        source: covered,
      );
      await _insertCoverage(
        conversationId: conversation.id,
        source: [source[3]],
        businessRepository: businessRepository,
        summaryId: 'summary-3',
      );

      final original = List<ChatMessage>.of(
        await chatService.loadMessages(conversation.id),
      );
      final result =
          await StoryMemoryContextBuilder(
            repository: storyRepository,
            chatService: chatService,
          ).prepare(
            messages: original,
            conversation: conversation,
            assistant: const Assistant(
              id: 'assistant-1',
              name: 'Story assistant',
              enableStoryMemory: true,
              storyMemoryRecentTurnRetention: 1,
            ),
          );

      expect(result.coverage?.hasHole, isTrue);
      expect(result.coverage?.staleFromOrder, isNull);
      expect(result.replacedHistory, isFalse);
      expect(
        result.messages.map((message) => message.id),
        original.map((message) => message.id),
      );
      expect(result.injection, isNull);
    },
  );

  test('stale automatic rows are excluded while manual rows remain', () async {
    final conversation = await _seedConversation(chatService, count: 2);
    final source = await StoryMemorySource.load(chatService, conversation.id);
    await storyRepository.applyPatch(
      patch: _characterPatch(
        conversation.id,
        source,
        summaryId: 'summary-auto',
        identity: 'Automatic identity',
      ),
      source: source,
    );
    await storyRepository.saveManualRow(
      conversationId: conversation.id,
      table: StoryMemoryTable.character,
      id: 'char-manual',
      data: {'characterId': 'char-manual', 'name': 'Manual character'},
    );
    await storyRepository.markStaleFromOrder(
      conversationId: conversation.id,
      order: 0,
    );

    final original = List<ChatMessage>.of(
      await chatService.loadMessages(conversation.id),
    );
    final result =
        await StoryMemoryContextBuilder(
          repository: storyRepository,
          chatService: chatService,
        ).prepare(
          messages: original,
          conversation: conversation,
          assistant: const Assistant(
            id: 'assistant-1',
            name: 'Story assistant',
            enableStoryMemory: true,
          ),
        );

    expect(
      result.messages.map((message) => message.id),
      original.map((message) => message.id),
    );
    expect(result.injection, contains('Manual character'));
    expect(result.injection, isNot(contains('Automatic identity')));
  });

  test(
    'empty source cannot inject automatic rows from an unverified checkpoint',
    () async {
      final conversation = await _seedConversation(chatService, count: 0);
      await businessRepository.upsertExtensionEntity(
        BusinessExtensionEntityValue(
          kind: StoryMemoryTable.character.wireName,
          id: 'char-auto',
          sortOrder: 0,
          ownerId: conversation.id,
          payload: jsonEncode({
            'characterId': 'char-auto',
            'name': 'Automatic character',
            'sourcePatchId': 'patch-auto',
          }),
        ),
      );
      await businessRepository.upsertExtensionEntity(
        BusinessExtensionEntityValue(
          kind: StoryMemoryRepository.checkpointKind,
          id: 'checkpoint-empty',
          sortOrder: 0,
          ownerId: conversation.id,
          payload: jsonEncode({
            'checkpointId': 'checkpoint-empty',
            'conversationId': conversation.id,
            'startOrder': 0,
            'endOrder': 0,
            'selectedVersionDigest': 'a' * 64,
            'patchId': 'patch-auto',
            'status': 'valid',
            'createdAt': DateTime.now().toUtc().microsecondsSinceEpoch,
          }),
        ),
      );
      await storyRepository.saveManualRow(
        conversationId: conversation.id,
        table: StoryMemoryTable.character,
        id: 'char-manual',
        data: {'characterId': 'char-manual', 'name': 'Manual character'},
      );

      final result =
          await StoryMemoryContextBuilder(
            repository: storyRepository,
            chatService: chatService,
          ).prepare(
            messages: const [],
            conversation: conversation,
            assistant: const Assistant(
              id: 'assistant-1',
              name: 'Story assistant',
              enableStoryMemory: true,
            ),
          );

      expect(result.messages, isEmpty);
      expect(result.injection, contains('Manual character'));
      expect(result.injection, isNot(contains('Automatic character')));
    },
  );

  test(
    'undo restores only facts from the still-valid prior checkpoint',
    () async {
      final conversation = await _seedConversation(chatService, count: 4);
      final source = await StoryMemorySource.load(chatService, conversation.id);
      final firstWindow = source.sublist(0, 2);
      final secondWindow = source.sublist(2, 4);
      await storyRepository.applyPatch(
        patch: _characterPatch(
          conversation.id,
          firstWindow,
          summaryId: 'summary-first',
          identity: 'First identity',
        ),
        source: firstWindow,
      );
      final second = await storyRepository.applyPatch(
        patch: _characterPatch(
          conversation.id,
          secondWindow,
          summaryId: 'summary-second',
          identity: 'Second identity',
        ),
        source: source,
      );
      await storyRepository.undoPatch(second.patchId);

      final result =
          await StoryMemoryContextBuilder(
            repository: storyRepository,
            chatService: chatService,
          ).prepare(
            messages: await chatService.loadMessages(conversation.id),
            conversation: conversation,
            assistant: const Assistant(
              id: 'assistant-1',
              name: 'Story assistant',
              enableStoryMemory: true,
              storyMemoryRecentTurnRetention: 1,
            ),
          );

      expect(result.injection, contains('First identity'));
      expect(result.injection, isNot(contains('Second identity')));
      expect(result.coverage?.coveredEndOrder, 1);
    },
  );
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

StoryMemoryPatch _summaryPatch(
  String conversationId,
  List<StoryMemorySourceItem> source,
  String summaryId,
) {
  final digest = StoryMemorySource.digest(source);
  return StoryMemoryPatch.parse({
    'schemaVersion': 1,
    'conversationId': conversationId,
    'sourceStartOrder': source.first.order,
    'sourceEndOrder': source.last.order,
    'sourceDigest': digest,
    'operations': [
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

StoryMemoryPatch _characterPatch(
  String conversationId,
  List<StoryMemorySourceItem> source, {
  required String summaryId,
  required String identity,
}) => StoryMemoryPatch.parse({
  'schemaVersion': 1,
  'conversationId': conversationId,
  'sourceStartOrder': source.first.order,
  'sourceEndOrder': source.last.order,
  'sourceDigest': StoryMemorySource.digest(source),
  'operations': [
    {
      'op': 'upsertCharacter',
      'characterId': 'char-1',
      'fields': {'name': 'Mara', 'identity': identity},
    },
    _summaryOperation(source, summaryId),
  ],
});

Map<String, dynamic> _summaryOperation(
  List<StoryMemorySourceItem> source,
  String summaryId,
) {
  final digest = StoryMemorySource.digest(source);
  return {
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
  };
}

Future<void> _insertCoverage({
  required BusinessRepository businessRepository,
  required String conversationId,
  required List<StoryMemorySourceItem> source,
  required String summaryId,
}) async {
  final digest = StoryMemorySource.digest(source);
  final start = source.first.order;
  final end = source.last.order;
  final checkpointId = 'checkpoint-$conversationId-$start';
  await businessRepository.upsertExtensionEntity(
    BusinessExtensionEntityValue(
      kind: StoryMemoryTable.plotSummary.wireName,
      id: summaryId,
      sortOrder: end,
      ownerId: conversationId,
      payload: jsonEncode({
        'summaryId': summaryId,
        'sourceStartOrder': start,
        'sourceEndOrder': end,
        'sourceDigest': digest,
        'sourceMessageIds': [for (final item in source) item.message.id],
        'summary': 'tail',
        'keyEntities': <String>[],
        'unresolvedThreads': <String>[],
      }),
    ),
  );
  await businessRepository.upsertExtensionEntity(
    BusinessExtensionEntityValue(
      kind: StoryMemoryRepository.checkpointKind,
      id: checkpointId,
      sortOrder: end,
      ownerId: conversationId,
      payload: jsonEncode({
        'checkpointId': checkpointId,
        'conversationId': conversationId,
        'startOrder': start,
        'endOrder': end,
        'selectedVersionDigest': digest,
        'patchId': 'patch-$conversationId-$start',
        'status': 'valid',
        'createdAt': DateTime.now().toUtc().microsecondsSinceEpoch,
      }),
    ),
  );
}
