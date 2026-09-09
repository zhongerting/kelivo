import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/business_data.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/business_settings_router.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_models.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_repository.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_source.dart';
import 'package:Kelivo/core/services/story_memory/story_memory_validator.dart';

void main() {
  late AppDatabase database;
  late BusinessRepository businessRepository;
  late StoryMemoryRepository repository;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    businessRepository = BusinessRepository(database);
    repository = StoryMemoryRepository(businessRepository: businessRepository);
    await database.customSelect('SELECT 1;').getSingle();
  });

  tearDown(() => database.close());

  test('patch parsing rejects unknown root and operation fields', () {
    final valid = <String, dynamic>{
      'schemaVersion': 1,
      'conversationId': 'conversation-a',
      'sourceStartOrder': 0,
      'sourceEndOrder': 0,
      'sourceDigest': 'a' * 64,
      'operations': [
        {
          'op': 'appendPlotSummary',
          'row': {
            'summaryId': 'summary-1',
            'sourceStartOrder': 0,
            'sourceEndOrder': 0,
            'sourceDigest': 'a' * 64,
            'sourceMessageIds': ['message-1'],
            'summary': 'A summary',
            'keyEntities': <String>[],
            'unresolvedThreads': <String>[],
          },
        },
      ],
    };

    expect(StoryMemoryPatch.parse(valid), isA<StoryMemoryPatch>());
    expect(
      () => StoryMemoryPatch.parse({...valid, 'execute': 'DROP TABLE'}),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => StoryMemoryPatch.parse({
        ...valid,
        'operations': [
          {
            'op': 'appendPlotSummary',
            'row': valid['operations'][0]['row'],
            'script': 'evil',
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'committed patch advances coverage and stays conversation scoped',
    () async {
      final sourceA = _source('conversation-a', 2);
      final sourceB = _source('conversation-b', 1);

      await repository.applyPatch(
        patch: _summaryPatch('conversation-a', sourceA, 'summary-a'),
        source: sourceA,
      );
      await repository.applyPatch(
        patch: _summaryPatch('conversation-b', sourceB, 'summary-b'),
        source: sourceB,
      );

      final snapshotA = await repository.read('conversation-a');
      final snapshotB = await repository.read('conversation-b');
      expect(snapshotA.rowsFor(StoryMemoryTable.plotSummary), hasLength(1));
      expect(
        snapshotA.rowsFor(StoryMemoryTable.plotSummary).single.id,
        'summary-a',
      );
      expect(snapshotB.rowsFor(StoryMemoryTable.plotSummary), hasLength(1));
      expect(
        snapshotB.rowsFor(StoryMemoryTable.plotSummary).single.id,
        'summary-b',
      );
      expect(snapshotA.checkpoints.single.endOrder, 1);
      expect(snapshotB.checkpoints.single.endOrder, 0);
    },
  );

  test(
    'pending patch survives read, confirms once, and can be discarded',
    () async {
      final sourceA = _source('conversation-a', 2);
      final pending = await repository.savePendingPatch(
        patch: _summaryPatch('conversation-a', sourceA, 'summary-a'),
        source: sourceA,
      );

      final before = await repository.read('conversation-a');
      expect(before.pendingPatches.single.id, pending.id);
      expect(before.pendingPatches.single.isPending, isTrue);
      expect(before.checkpoints, isEmpty);
      expect(
        (await repository.inspectCoverage(
          'conversation-a',
          sourceA,
        )).coveredEndOrder,
        -1,
      );

      final applied = await repository.confirmPendingPatch(
        pendingId: pending.id,
        source: sourceA,
      );
      expect(applied.sourceEndOrder, 1);
      final after = await repository.read('conversation-a');
      expect(after.pendingPatches.single.status, 'applied');
      expect(after.checkpoints.single.patchId, applied.patchId);
      expect(
        after.patches.where((patch) => patch.status == 'committed'),
        hasLength(1),
      );
      await repository.undoPatch(applied.patchId);
      final undone = await repository.read('conversation-a');
      expect(undone.rows, isEmpty);
      expect(undone.checkpoints.single.status, 'undone');
      expect(undone.patches.single.status, 'undone');
      await expectLater(
        repository.confirmPendingPatch(pendingId: pending.id, source: sourceA),
        throwsA(
          isA<StoryMemoryValidationException>().having(
            (error) => error.code,
            'code',
            'story_pending_not_active',
          ),
        ),
      );

      final sourceB = _source('conversation-b', 1);
      final rejected = await repository.savePendingPatch(
        patch: _summaryPatch('conversation-b', sourceB, 'summary-b'),
        source: sourceB,
      );
      await repository.discardPendingPatch(rejected.id);
      final discarded = await repository.read('conversation-b');
      expect(discarded.pendingPatches.single.status, 'discarded');
      expect(discarded.checkpoints, isEmpty);
    },
  );

  test(
    'locked character fields reject model writes without changing rows',
    () async {
      await repository.saveManualRow(
        conversationId: 'conversation-a',
        table: StoryMemoryTable.character,
        id: 'char-1',
        data: {
          'characterId': 'char-1',
          'name': 'Mara',
          'coreTraits': 'calm',
          'lockedFields': ['coreTraits'],
        },
      );
      final source = _source('conversation-a', 1);
      final patch = _patch(
        conversationId: 'conversation-a',
        source: source,
        summaryId: 'summary-a',
        operations: [
          {
            'op': 'upsertCharacter',
            'characterId': 'char-1',
            'fields': {'coreTraits': 'reckless'},
          },
          _summaryOperation(source, 'summary-a'),
        ],
      );

      await expectLater(
        repository.applyPatch(patch: patch, source: source),
        throwsA(
          isA<StoryMemoryValidationException>().having(
            (error) => error.code,
            'code',
            'story_locked_field',
          ),
        ),
      );
      final snapshot = await repository.read('conversation-a');
      expect(
        snapshot
            .rowById(StoryMemoryTable.character, 'char-1')!
            .data['coreTraits'],
        'calm',
      );
      expect(snapshot.checkpoints, isEmpty);
      expect(snapshot.patches.last.status, 'failed');
    },
  );

  test('manual row changes are audited and can be undone', () async {
    await repository.saveManualRow(
      conversationId: 'conversation-a',
      table: StoryMemoryTable.character,
      id: 'char-manual',
      data: {'characterId': 'char-manual', 'name': 'Mara'},
    );

    final committed = (await repository.read('conversation-a')).patches.single;
    expect(committed.manual, isTrue);
    expect(committed.sourceStartOrder, isNull);
    expect(committed.createdRows.single.id, 'char-manual');

    await repository.undoPatch(committed.id);

    final snapshot = await repository.read('conversation-a');
    expect(snapshot.rowById(StoryMemoryTable.character, 'char-manual'), isNull);
    expect(snapshot.patches.single.status, 'undone');
  });

  test(
    'manual edits invalidate related coverage and record deletion post-images',
    () async {
      final source = _source('conversation-a', 2);
      await repository.applyPatch(
        patch: _patch(
          conversationId: 'conversation-a',
          source: source,
          summaryId: 'summary-auto',
          operations: [
            {
              'op': 'upsertCharacter',
              'characterId': 'char-1',
              'fields': {'name': 'Mara', 'identity': 'Scout'},
            },
            _summaryOperation(source, 'summary-auto'),
          ],
        ),
        source: source,
      );
      await repository.saveManualRow(
        conversationId: 'conversation-a',
        table: StoryMemoryTable.character,
        id: 'char-1',
        data: {
          'characterId': 'char-1',
          'name': 'Mara',
          'identity': 'Updated by user',
        },
      );

      var snapshot = await repository.read('conversation-a');
      expect(snapshot.checkpoints.single.status, 'stale');
      final manualEdit = snapshot.patches.last;
      expect(manualEdit.manual, isTrue);
      expect(manualEdit.beforeRows.single.data['identity'], 'Scout');
      expect(manualEdit.afterRows.single.data['identity'], 'Updated by user');

      await repository.deleteManualRow(
        conversationId: 'conversation-a',
        table: StoryMemoryTable.character,
        id: 'char-1',
      );
      snapshot = await repository.read('conversation-a');
      final manualDelete = snapshot.patches.last;
      expect(manualDelete.manual, isTrue);
      expect(manualDelete.deletedRows.single.id, 'char-1');
      expect(snapshot.rowById(StoryMemoryTable.character, 'char-1'), isNull);
    },
  );

  test('checkpoint insertion failure rolls back rows and checkpoint', () async {
    await database.customStatement('''
CREATE TRIGGER fail_story_checkpoint
BEFORE INSERT ON extension_entity_rows
WHEN NEW.kind = 'story_checkpoint'
BEGIN
  SELECT RAISE(ABORT, 'injected_story_checkpoint_failure');
END;
''');
    final source = _source('conversation-a', 2);

    await expectLater(
      repository.applyPatch(
        patch: _summaryPatch('conversation-a', source, 'summary-a'),
        source: source,
      ),
      throwsA(anything),
    );

    final snapshot = await repository.read('conversation-a');
    expect(snapshot.rows, isEmpty);
    expect(snapshot.checkpoints, isEmpty);
    expect(snapshot.patches, hasLength(1));
    expect(snapshot.patches.single.status, 'failed');
  });

  test(
    'coverage reports a gap and digest changes as fail-open conditions',
    () async {
      final source = _source('conversation-a', 3);
      final tail = [source[2]];
      await _insertCoverage(
        businessRepository: businessRepository,
        conversationId: 'conversation-a',
        source: tail,
        start: 2,
        end: 2,
        summaryId: 'summary-tail',
      );

      final hole = await repository.inspectCoverage('conversation-a', source);
      expect(hole.hasHole, isTrue);
      expect(hole.staleFromOrder, isNull);
      expect(hole.coveredEndOrder, -1);

      final sourceB = _source('conversation-b', 1);
      final first = [sourceB.first];
      await _insertCoverage(
        businessRepository: businessRepository,
        conversationId: 'conversation-b',
        source: first,
        start: 0,
        end: 0,
        summaryId: 'summary-first',
      );
      final changed = [
        (
          message: ChatMessage(
            id: sourceB.first.message.id,
            role: 'user',
            content: 'edited',
            conversationId: 'conversation-b',
            groupId: sourceB.first.message.groupId,
            version: sourceB.first.message.version,
          ),
          order: 0,
        ),
      ];
      final stale = await repository.inspectCoverage('conversation-b', changed);
      expect(stale.hasHole, isTrue);
      expect(stale.staleFromOrder, 0);
    },
  );

  test('source windows reject foreign messages and order holes', () async {
    final foreignSource = _source('conversation-b', 1);
    await expectLater(
      repository.applyPatch(
        patch: _summaryPatch('conversation-a', foreignSource, 'summary-a'),
        source: foreignSource,
      ),
      throwsA(
        isA<StoryMemoryValidationException>().having(
          (error) => error.code,
          'code',
          'story_source_conversation',
        ),
      ),
    );

    final completeSource = _source('conversation-a', 3);
    final gappedSource = [completeSource[0], completeSource[2]];
    await expectLater(
      repository.applyPatch(
        patch: _summaryPatch('conversation-a', gappedSource, 'summary-gap'),
        source: gappedSource,
      ),
      throwsA(
        isA<StoryMemoryValidationException>().having(
          (error) => error.code,
          'code',
          'story_source_order',
        ),
      ),
    );
  });

  test('new relationships require both character endpoints', () async {
    final source = _source('conversation-a', 1);
    final patch = _patch(
      conversationId: 'conversation-a',
      source: source,
      summaryId: 'summary-a',
      operations: [
        {
          'op': 'upsertCharacter',
          'characterId': 'char-1',
          'fields': {'name': 'Mara'},
        },
        {
          'op': 'upsertCharacter',
          'characterId': 'char-2',
          'fields': {'name': 'Ivo'},
        },
        {
          'op': 'upsertRelationship',
          'relationshipId': 'rel-1',
          'fields': {'fromCharacterId': 'char-1', 'relationType': 'ally'},
        },
        _summaryOperation(source, 'summary-a'),
      ],
    );

    await expectLater(
      repository.applyPatch(patch: patch, source: source),
      throwsA(
        isA<StoryMemoryValidationException>().having(
          (error) => error.code,
          'code',
          'story_character_reference',
        ),
      ),
    );
    expect((await repository.read('conversation-a')).checkpoints, isEmpty);
  });

  test(
    'business snapshot round trip preserves story extension state',
    () async {
      final source = _source('conversation-a', 4);
      await repository.applyPatch(
        patch: _summaryPatch(
          'conversation-a',
          source.sublist(0, 2),
          'summary-first',
        ),
        source: source,
      );
      final pending = await repository.savePendingPatch(
        patch: _summaryPatch(
          'conversation-a',
          source.sublist(2),
          'summary-second',
        ),
        source: source,
      );

      final exported = BusinessSettingsRouter.exportSnapshot(
        await businessRepository.readSnapshot(),
      );
      final restoredDatabase = AppDatabase(NativeDatabase.memory());
      try {
        final restoredBusiness = BusinessRepository(restoredDatabase);
        await restoredBusiness.replaceSnapshot(
          BusinessSettingsRouter.normalizeAndRoute(exported),
        );
        final restored = await StoryMemoryRepository(
          businessRepository: restoredBusiness,
        ).read('conversation-a');

        expect(
          restored.rows.map((row) => row.toJson()),
          (await repository.read(
            'conversation-a',
          )).rows.map((row) => row.toJson()),
        );
        expect(
          restored.checkpoints.map((checkpoint) => checkpoint.toJson()),
          (await repository.read(
            'conversation-a',
          )).checkpoints.map((checkpoint) => checkpoint.toJson()),
        );
        expect(restored.pendingPatches.single.id, pending.id);
        expect(restored.pendingPatches.single.status, 'pending');
      } finally {
        await restoredDatabase.close();
      }
    },
  );
}

List<StoryMemorySourceItem> _source(String conversationId, int count) => [
  for (var index = 0; index < count; index++)
    (
      message: ChatMessage(
        id: '$conversationId-message-$index',
        role: index.isEven ? 'user' : 'assistant',
        content: 'message $index',
        conversationId: conversationId,
        groupId: '$conversationId-group-$index',
        version: 0,
      ),
      order: index,
    ),
];

StoryMemoryPatch _summaryPatch(
  String conversationId,
  List<StoryMemorySourceItem> source,
  String summaryId,
) => _patch(
  conversationId: conversationId,
  source: source,
  summaryId: summaryId,
  operations: [_summaryOperation(source, summaryId)],
);

StoryMemoryPatch _patch({
  required String conversationId,
  required List<StoryMemorySourceItem> source,
  required String summaryId,
  required List<Map<String, dynamic>> operations,
}) {
  final digest = StoryMemorySource.digest(source);
  return StoryMemoryPatch.parse({
    'schemaVersion': 1,
    'conversationId': conversationId,
    'sourceStartOrder': source.first.order,
    'sourceEndOrder': source.last.order,
    'sourceDigest': digest,
    'operations': operations,
  });
}

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
  required int start,
  required int end,
  required String summaryId,
}) async {
  final digest = StoryMemorySource.digest(source);
  final now = DateTime.now().toUtc().microsecondsSinceEpoch;
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
      id: 'checkpoint-$conversationId-$start',
      sortOrder: end,
      ownerId: conversationId,
      payload: jsonEncode({
        'checkpointId': 'checkpoint-$conversationId-$start',
        'conversationId': conversationId,
        'startOrder': start,
        'endOrder': end,
        'selectedVersionDigest': digest,
        'patchId': 'patch-$conversationId-$start',
        'status': 'valid',
        'createdAt': now,
      }),
    ),
  );
}
