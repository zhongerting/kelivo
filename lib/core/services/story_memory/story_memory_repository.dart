import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../database/business_data.dart';
import '../../database/business_repository.dart';
import 'story_memory_models.dart';
import 'story_memory_source.dart';
import 'story_memory_validator.dart';

final class StoryMemoryApplyResult {
  const StoryMemoryApplyResult({
    required this.patchId,
    required this.checkpointId,
    required this.sourceStartOrder,
    required this.sourceEndOrder,
  });

  final String patchId;
  final String checkpointId;
  final int sourceStartOrder;
  final int sourceEndOrder;
}

final class StoryMemoryCoverage {
  const StoryMemoryCoverage({
    required this.coveredEndOrder,
    required this.hasHole,
    required this.staleFromOrder,
    required this.validCheckpoints,
  });

  final int coveredEndOrder;
  final bool hasHole;
  final int? staleFromOrder;
  final List<StoryMemoryCheckpoint> validCheckpoints;

  bool get hasCoverage => coveredEndOrder >= 0;
}

/// Persistence boundary for the conversation-scoped story-memory domain.
///
/// The generic extension table is only a storage primitive. This repository
/// owns story row kinds, patch transactions, checkpoint semantics, and the
/// fail-open rules used by context assembly.
final class StoryMemoryRepository {
  StoryMemoryRepository({required this.businessRepository});

  static const String patchKind = 'story_patch';
  static const String checkpointKind = 'story_checkpoint';
  static const String pendingPatchKind = 'story_pending_patch';

  final BusinessRepository businessRepository;
  static const Uuid _uuid = Uuid();

  Future<StoryMemorySnapshot> read(String conversationId) async {
    final id = _requireConversationId(conversationId);
    final extensionRows = await businessRepository.readExtensionEntities(
      ownerId: id,
    );
    return _snapshotFromExtensionRows(id, extensionRows);
  }

  Future<StoryMemoryCoverage> inspectCoverage(
    String conversationId,
    List<StoryMemorySourceItem> source,
  ) async {
    final snapshot = await read(conversationId);
    return _inspectCoverage(snapshot, source);
  }

  /// Apply one complete model patch. All row writes and the checkpoint happen
  /// in one SQLite transaction. A source mismatch or validation error throws;
  /// callers must leave the previous checkpoint untouched and retain history.
  Future<StoryMemoryApplyResult> applyPatch({
    required StoryMemoryPatch patch,
    required List<StoryMemorySourceItem> source,
  }) async {
    final patchId = _uuid.v4();
    try {
      return await businessRepository.transaction(() async {
        return _applyPatchInTransaction(
          patch: patch,
          source: source,
          patchId: patchId,
        );
      });
    } catch (error) {
      // A failed patch is intentionally not written in the same transaction:
      // the model rows and checkpoint must roll back together. The failure is
      // best-effort audit data and can never affect the fail-open decision.
      await _recordFailure(
        patchId: patchId,
        patch: patch,
        error: _failureCode(error),
      );
      rethrow;
    }
  }

  /// Stores a validated patch for later review. Pending patches never move
  /// the coverage watermark and are never considered by context assembly.
  Future<StoryMemoryPendingPatch> savePendingPatch({
    required StoryMemoryPatch patch,
    required List<StoryMemorySourceItem> source,
  }) async {
    final auditId = _uuid.v4();
    try {
      return await businessRepository.transaction(() async {
        final snapshot = await read(patch.conversationId);
        await _validatePatchForApplication(
          patch: patch,
          source: source,
          snapshot: snapshot,
        );
        for (final pending in snapshot.pendingPatches) {
          if (pending.isPending &&
              pending.patch.sourceStartOrder == patch.sourceStartOrder &&
              pending.patch.sourceEndOrder == patch.sourceEndOrder &&
              pending.patch.sourceDigest == patch.sourceDigest) {
            return pending;
          }
        }
        final pending = StoryMemoryPendingPatch(
          id: _uuid.v4(),
          conversationId: patch.conversationId,
          patch: patch,
          status: 'pending',
          createdAt: DateTime.now().toUtc(),
        );
        await businessRepository.upsertExtensionEntity(
          BusinessExtensionEntityValue(
            kind: pendingPatchKind,
            id: pending.id,
            sortOrder: patch.sourceEndOrder,
            ownerId: patch.conversationId,
            payload: jsonEncode(pending.toJson()),
          ),
        );
        return pending;
      });
    } catch (error) {
      await _recordFailure(
        patchId: auditId,
        patch: patch,
        error: _failureCode(error),
      );
      rethrow;
    }
  }

  /// Applies an active pending patch after the caller has reviewed it.
  /// Re-reading the pending row inside the transaction prevents two UI taps
  /// from committing the same patch twice.
  Future<StoryMemoryApplyResult> confirmPendingPatch({
    required String pendingId,
    required List<StoryMemorySourceItem> source,
  }) async {
    final rawPending = (await businessRepository.readExtensionEntities(
      kind: pendingPatchKind,
    )).where((row) => row.id == pendingId).firstOrNull;
    if (rawPending == null) {
      throw const StoryMemoryValidationException('story_pending_missing');
    }
    final initial = StoryMemoryPendingPatch.fromExtension(rawPending);
    final patchId = _uuid.v4();
    var attempted = false;
    try {
      return await businessRepository.transaction(() async {
        final currentRaw = (await businessRepository.readExtensionEntities(
          kind: pendingPatchKind,
        )).where((row) => row.id == pendingId).firstOrNull;
        if (currentRaw == null) {
          throw const StoryMemoryValidationException('story_pending_missing');
        }
        final current = StoryMemoryPendingPatch.fromExtension(currentRaw);
        if (!current.isPending) {
          throw StoryMemoryValidationException(
            'story_pending_not_active',
            current.status,
          );
        }
        attempted = true;
        final applied = await _applyPatchInTransaction(
          patch: current.patch,
          source: source,
          patchId: patchId,
        );
        final completed = current.copyWith(
          status: 'applied',
          appliedPatchId: applied.patchId,
        );
        await businessRepository.upsertExtensionEntity(
          currentRaw.copyWith(payload: jsonEncode(completed.toJson())),
        );
        return applied;
      });
    } catch (error) {
      if (attempted) {
        await _recordFailure(
          patchId: patchId,
          patch: initial.patch,
          error: _failureCode(error),
        );
        if (_invalidatesPendingSource(error)) {
          await _markPendingStatus(
            pendingId: pendingId,
            status: 'stale',
            error: _failureCode(error),
          );
        }
      }
      rethrow;
    }
  }

  /// Rejects a pending patch without changing rows or coverage.
  Future<void> discardPendingPatch(String pendingId) async {
    final rawPending = (await businessRepository.readExtensionEntities(
      kind: pendingPatchKind,
    )).where((row) => row.id == pendingId).firstOrNull;
    if (rawPending == null) return;
    final pending = StoryMemoryPendingPatch.fromExtension(rawPending);
    if (!pending.isPending) return;
    await _markPendingStatus(pendingId: pendingId, status: 'discarded');
  }

  /// Reverts the latest committed patch when its post-image is still intact.
  ///
  /// Automatic memory must never overwrite a later manual edit. Patch logs
  /// therefore carry before/after row images, and undo is rejected unless the
  /// target is the latest committed patch with a still-valid checkpoint.
  Future<void> undoPatch(String patchId) async {
    final rawPatch = (await businessRepository.readExtensionEntities(
      kind: patchKind,
    )).where((row) => row.id == patchId).firstOrNull;
    if (rawPatch == null) {
      throw const StoryMemoryValidationException('story_patch_missing');
    }
    final initial = StoryMemoryPatchLog.fromExtension(rawPatch);
    if (initial.status != 'committed') {
      throw StoryMemoryValidationException('story_undo_not_committed', patchId);
    }
    if (initial.afterRows.isEmpty &&
        initial.beforeRows.isEmpty &&
        initial.createdRows.isEmpty &&
        initial.deletedRows.isEmpty) {
      throw StoryMemoryValidationException(
        'story_undo_metadata_missing',
        patchId,
      );
    }

    await businessRepository.transaction(() async {
      final currentPatchRow = (await businessRepository.readExtensionEntities(
        kind: patchKind,
      )).where((row) => row.id == patchId).firstOrNull;
      if (currentPatchRow == null) {
        throw const StoryMemoryValidationException('story_patch_missing');
      }
      final currentPatch = StoryMemoryPatchLog.fromExtension(currentPatchRow);
      if (currentPatch.status != 'committed') {
        throw StoryMemoryValidationException(
          'story_undo_not_committed',
          patchId,
        );
      }
      final snapshot = await read(currentPatch.conversationId);
      final hasLaterPatch = snapshot.patches.any(
        (candidate) =>
            candidate.id != patchId &&
            candidate.status == 'committed' &&
            candidate.createdAt.isAfter(currentPatch.createdAt),
      );
      if (hasLaterPatch) {
        throw StoryMemoryValidationException('story_undo_not_latest', patchId);
      }
      final checkpoint = currentPatch.manual
          ? null
          : snapshot.checkpoints
                .where(
                  (candidate) =>
                      candidate.patchId == patchId &&
                      candidate.status == 'valid',
                )
                .firstOrNull;
      if (!currentPatch.manual && checkpoint == null) {
        throw StoryMemoryValidationException(
          'story_undo_checkpoint_unavailable',
          patchId,
        );
      }
      final currentRows = <String, StoryMemoryRow>{
        for (final row in snapshot.rows) _rowKey(row.table, row.id): row,
      };
      for (final expected in currentPatch.afterRows) {
        final actual = currentRows[_rowKey(expected.table, expected.id)];
        if (actual == null || !_sameRow(actual, expected)) {
          throw StoryMemoryValidationException(
            'story_undo_row_modified',
            expected.id,
          );
        }
      }
      for (final expected in currentPatch.deletedRows) {
        if (currentRows.containsKey(_rowKey(expected.table, expected.id))) {
          throw StoryMemoryValidationException(
            'story_undo_row_modified',
            expected.id,
          );
        }
      }
      for (final created in currentPatch.createdRows) {
        await businessRepository.deleteExtensionEntity(
          kind: created.table.wireName,
          id: created.id,
          ownerId: currentPatch.conversationId,
        );
      }
      for (final before in currentPatch.beforeRows) {
        await businessRepository.upsertExtensionEntity(
          _extensionRow(before, currentPatch.conversationId),
        );
      }
      final undonePatch = currentPatch.copyWith(status: 'undone');
      await businessRepository.upsertExtensionEntity(
        currentPatchRow.copyWith(payload: jsonEncode(undonePatch.toJson())),
      );
      if (checkpoint != null) {
        final undoneCheckpoint = StoryMemoryCheckpoint(
          id: checkpoint.id,
          conversationId: checkpoint.conversationId,
          startOrder: checkpoint.startOrder,
          endOrder: checkpoint.endOrder,
          selectedVersionDigest: checkpoint.selectedVersionDigest,
          patchId: checkpoint.patchId,
          status: 'undone',
          createdAt: checkpoint.createdAt,
        );
        final rawCheckpoint = (await businessRepository.readExtensionEntities(
          kind: checkpointKind,
        )).where((row) => row.id == checkpoint.id).firstOrNull;
        if (rawCheckpoint == null) {
          throw const StoryMemoryValidationException(
            'story_undo_checkpoint_missing',
          );
        }
        await businessRepository.upsertExtensionEntity(
          rawCheckpoint.copyWith(
            payload: jsonEncode(undoneCheckpoint.toJson()),
          ),
        );
      }
    });
  }

  static String _failureCode(Object error) {
    final value = error.toString();
    return value.length <= 512 ? value : value.substring(0, 512);
  }

  Future<void> markStaleFromOrder({
    required String conversationId,
    required int order,
  }) async {
    final id = _requireConversationId(conversationId);
    await businessRepository.transaction(
      () => _markStaleFromOrderInTransaction(conversationId: id, order: order),
    );
  }

  Future<void> _markStaleFromOrderInTransaction({
    required String conversationId,
    required int order,
  }) async {
    final rows = await businessRepository.readExtensionEntities(
      ownerId: conversationId,
    );
    for (final raw in rows) {
      if (raw.kind != checkpointKind) continue;
      final checkpoint = StoryMemoryCheckpoint.fromExtension(raw);
      if (checkpoint.status != 'valid' || checkpoint.endOrder < order) {
        continue;
      }
      final stale = StoryMemoryCheckpoint(
        id: checkpoint.id,
        conversationId: checkpoint.conversationId,
        startOrder: checkpoint.startOrder,
        endOrder: checkpoint.endOrder,
        selectedVersionDigest: checkpoint.selectedVersionDigest,
        patchId: checkpoint.patchId,
        status: 'stale',
        createdAt: checkpoint.createdAt,
      );
      await businessRepository.upsertExtensionEntity(
        raw.copyWith(payload: jsonEncode(stale.toJson())),
      );
    }
  }

  Future<void> _invalidateCheckpointsForManualRowInTransaction({
    required StoryMemorySnapshot snapshot,
    required StoryMemoryRow? previous,
    required StoryMemoryRow? next,
  }) async {
    final starts = <int>{
      for (final row in [previous, next])
        if (row?.data['sourceStartOrder'] is int &&
            (row!.data['sourceStartOrder'] as int) >= 0)
          row.data['sourceStartOrder'] as int,
    };
    if (starts.isEmpty) return;
    final earliest = starts.reduce(
      (left, right) => left < right ? left : right,
    );
    await _markStaleFromOrderInTransaction(
      conversationId: snapshot.conversationId,
      order: earliest,
    );
  }

  /// Manual row editing is deliberately separate from model patching. It may
  /// change locks, but it never rewrites a source checkpoint or chat message.
  /// The row change, its audit image, and checkpoint invalidation are atomic.
  Future<void> saveManualRow({
    required String conversationId,
    required StoryMemoryTable table,
    required String id,
    required Map<String, dynamic> data,
    int sortOrder = 0,
  }) async {
    final conversation = _requireConversationId(conversationId);
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id');
    if (table == StoryMemoryTable.event ||
        table == StoryMemoryTable.plotSummary) {
      // Manual edits may update an event/summary, but their stored identity
      // must remain stable and the payload must still be an object.
      if (table == StoryMemoryTable.event && data['eventId'] != id) {
        throw ArgumentError.value(data, 'data');
      }
      if (table == StoryMemoryTable.plotSummary && data['summaryId'] != id) {
        throw ArgumentError.value(data, 'data');
      }
    }
    // A manual save is an explicit user-authored fact. Do not let a copied
    // automatic row keep its old patch provenance and disappear when that
    // checkpoint later becomes stale.
    final manualData = Map<String, dynamic>.from(data)..remove('sourcePatchId');
    final row = StoryMemoryRow(
      table: table,
      id: id,
      sortOrder: sortOrder < 0 ? 0 : sortOrder,
      ownerId: conversation,
      data: manualData,
    );
    _validateJsonObject(row.data);
    _validateManualIdentity(table, id, row.data);
    await businessRepository.transaction(() async {
      final snapshot = await read(conversation);
      final collisions = await businessRepository.readExtensionEntities(
        kind: table.wireName,
      );
      if (collisions.any(
        (candidate) => candidate.id == id && candidate.ownerId != conversation,
      )) {
        throw const StoryMemoryValidationException('story_id_collision');
      }
      final previous = snapshot.rowById(table, id);
      if (previous != null && _sameRow(previous, row)) return;
      await _invalidateCheckpointsForManualRowInTransaction(
        snapshot: snapshot,
        previous: previous,
        next: row,
      );
      await businessRepository.upsertExtensionEntity(
        _extensionRow(row, conversation),
      );
      final patchId = _uuid.v4();
      final patchLog = StoryMemoryPatchLog(
        id: patchId,
        conversationId: conversation,
        sourceStartOrder: null,
        sourceEndOrder: null,
        sourceDigest: null,
        status: 'committed',
        createdAt: DateTime.now().toUtc(),
        manual: true,
        operations: [
          {
            'op': 'manualUpsertRow',
            'table': table.wireName,
            'id': id,
            'sortOrder': row.sortOrder,
            'data': row.data,
          },
        ],
        beforeRows: previous == null ? const [] : [previous],
        afterRows: [row],
        createdRows: previous == null ? [row] : const [],
      );
      await businessRepository.upsertExtensionEntity(
        BusinessExtensionEntityValue(
          kind: patchKind,
          id: patchId,
          sortOrder: row.sortOrder,
          ownerId: conversation,
          payload: jsonEncode(patchLog.toJson()),
        ),
      );
    });
  }

  Future<void> deleteManualRow({
    required String conversationId,
    required StoryMemoryTable table,
    required String id,
  }) async {
    final conversation = _requireConversationId(conversationId);
    if (id.trim().isEmpty) return;
    await businessRepository.transaction(() async {
      final snapshot = await read(conversation);
      final previous = snapshot.rowById(table, id);
      if (previous == null) return;
      await _invalidateCheckpointsForManualRowInTransaction(
        snapshot: snapshot,
        previous: previous,
        next: null,
      );
      await businessRepository.deleteExtensionEntity(
        kind: table.wireName,
        id: id,
        ownerId: conversation,
      );
      final patchId = _uuid.v4();
      final patchLog = StoryMemoryPatchLog(
        id: patchId,
        conversationId: conversation,
        sourceStartOrder: null,
        sourceEndOrder: null,
        sourceDigest: null,
        status: 'committed',
        createdAt: DateTime.now().toUtc(),
        manual: true,
        operations: [
          {'op': 'manualDeleteRow', 'table': table.wireName, 'id': id},
        ],
        beforeRows: [previous],
        deletedRows: [previous],
      );
      await businessRepository.upsertExtensionEntity(
        BusinessExtensionEntityValue(
          kind: patchKind,
          id: patchId,
          sortOrder: previous.sortOrder,
          ownerId: conversation,
          payload: jsonEncode(patchLog.toJson()),
        ),
      );
    });
  }

  Future<void> clear(String conversationId) async {
    final id = _requireConversationId(conversationId);
    await businessRepository.transaction(() async {
      final rows = await businessRepository.readExtensionEntities(ownerId: id);
      for (final row in rows) {
        if (row.kind.startsWith('story_')) {
          await businessRepository.deleteExtensionEntity(
            kind: row.kind,
            id: row.id,
            ownerId: id,
          );
        }
      }
    });
  }

  Future<StoryMemoryApplyResult> _applyPatchInTransaction({
    required StoryMemoryPatch patch,
    required List<StoryMemorySourceItem> source,
    required String patchId,
  }) async {
    final snapshot = await read(patch.conversationId);
    await _validatePatchForApplication(
      patch: patch,
      source: source,
      snapshot: snapshot,
    );

    final rows = <String, StoryMemoryRow>{
      for (final row in snapshot.rows) _rowKey(row.table, row.id): row,
    };
    final validPatchIds = snapshot.checkpoints
        .where((checkpoint) => checkpoint.status == 'valid')
        .map((checkpoint) => checkpoint.patchId)
        .toSet();
    final beforeRows = <StoryMemoryRow>[];
    final createdKeys = <String>{};
    for (final operation in patch.operations) {
      final target = _targetForOperation(rows, operation);
      if (target.row == null) {
        createdKeys.add(target.key);
      } else {
        beforeRows.add(target.row!);
      }
    }
    final sourceIds = [
      for (final item in StoryMemorySource.range(
        source,
        startOrder: patch.sourceStartOrder,
        endOrder: patch.sourceEndOrder,
      ))
        item.message.id,
    ];
    final now = DateTime.now().toUtc();
    for (final operation in patch.operations) {
      _applyOperation(
        rows,
        operation,
        sourceIds: sourceIds,
        sourceStartOrder: patch.sourceStartOrder,
        sourceEndOrder: patch.sourceEndOrder,
        sourceDigest: patch.sourceDigest,
        now: now,
        patchId: patchId,
        validPatchIds: validPatchIds,
      );
    }
    final createdRows = [
      for (final key in createdKeys)
        if (rows[key] case final row?) row,
    ];
    final changedKeys = <String>{
      for (final row in beforeRows) _rowKey(row.table, row.id),
      ...createdKeys,
    };
    final afterRows = [
      for (final key in changedKeys)
        if (rows[key] case final row?) row,
    ];

    final patchLog = StoryMemoryPatchLog(
      id: patchId,
      conversationId: patch.conversationId,
      sourceStartOrder: patch.sourceStartOrder,
      sourceEndOrder: patch.sourceEndOrder,
      sourceDigest: patch.sourceDigest,
      status: 'committed',
      createdAt: now,
      operations: [
        for (final operation in patch.operations) operation.toJson(),
      ],
      beforeRows: beforeRows,
      afterRows: afterRows,
      createdRows: createdRows,
    );
    final checkpointId = _uuid.v4();
    final checkpoint = StoryMemoryCheckpoint(
      id: checkpointId,
      conversationId: patch.conversationId,
      startOrder: patch.sourceStartOrder,
      endOrder: patch.sourceEndOrder,
      selectedVersionDigest: patch.sourceDigest,
      patchId: patchId,
      status: 'valid',
      createdAt: now,
    );

    for (final row in rows.values) {
      final existing = snapshot.rowById(row.table, row.id);
      if (existing != null && _sameRow(existing, row)) continue;
      await businessRepository.upsertExtensionEntity(
        _extensionRow(row, patch.conversationId),
      );
    }
    await businessRepository.upsertExtensionEntity(
      BusinessExtensionEntityValue(
        kind: patchKind,
        id: patchId,
        sortOrder: patch.sourceEndOrder,
        ownerId: patch.conversationId,
        payload: jsonEncode(patchLog.toJson()),
      ),
    );
    await businessRepository.upsertExtensionEntity(
      BusinessExtensionEntityValue(
        kind: checkpointKind,
        id: checkpointId,
        sortOrder: patch.sourceEndOrder,
        ownerId: patch.conversationId,
        payload: jsonEncode(checkpoint.toJson()),
      ),
    );
    return StoryMemoryApplyResult(
      patchId: patchId,
      checkpointId: checkpointId,
      sourceStartOrder: patch.sourceStartOrder,
      sourceEndOrder: patch.sourceEndOrder,
    );
  }

  Future<void> _validatePatchForApplication({
    required StoryMemoryPatch patch,
    required List<StoryMemorySourceItem> source,
    required StoryMemorySnapshot snapshot,
  }) async {
    _validateSourceWindow(patch, source);
    final coverage = _inspectCoverage(snapshot, source);
    if (coverage.staleFromOrder != null || coverage.hasHole) {
      throw StoryMemoryValidationException(
        'story_source_stale',
        '${coverage.staleFromOrder}',
      );
    }
    final expectedStart = coverage.hasCoverage
        ? coverage.coveredEndOrder + 1
        : (source.isEmpty ? 0 : source.first.order);
    if (patch.sourceStartOrder != expectedStart) {
      throw StoryMemoryValidationException(
        'story_coverage_gap',
        '${patch.sourceStartOrder}:$expectedStart',
      );
    }
    StoryMemoryValidator.validatePatch(patch, snapshot);
    final allExtensionRows = await businessRepository.readExtensionEntities();
    _validateGlobalIds(patch, allExtensionRows, patch.conversationId);
  }

  Future<void> _markPendingStatus({
    required String pendingId,
    required String status,
    String? error,
  }) async {
    try {
      await businessRepository.transaction(() async {
        final raw = (await businessRepository.readExtensionEntities(
          kind: pendingPatchKind,
        )).where((row) => row.id == pendingId).firstOrNull;
        if (raw == null) return;
        final pending = StoryMemoryPendingPatch.fromExtension(raw);
        if (!pending.isPending && status != 'pending') return;
        final updated = pending.copyWith(status: status, error: error);
        await businessRepository.upsertExtensionEntity(
          raw.copyWith(payload: jsonEncode(updated.toJson())),
        );
      });
    } catch (_) {
      // Pending-state bookkeeping is secondary to the fail-open request path.
    }
  }

  static bool _invalidatesPendingSource(Object error) {
    final text = error.toString();
    return text.startsWith('story_source_digest') ||
        text.startsWith('story_source_stale') ||
        text.startsWith('story_coverage_gap') ||
        text.startsWith('story_source_ids');
  }

  ({String key, StoryMemoryRow? row}) _targetForOperation(
    Map<String, StoryMemoryRow> rows,
    StoryMemoryOperation operation,
  ) {
    switch (operation.type) {
      case StoryMemoryOperationType.upsertCharacter:
        final key = _rowKey(StoryMemoryTable.character, operation.id!);
        return (key: key, row: rows[key]);
      case StoryMemoryOperationType.upsertCharacterState:
        final old = rows.values.cast<StoryMemoryRow?>().firstWhere(
          (row) =>
              row?.table == StoryMemoryTable.characterState &&
              row?.data['characterId'] == operation.id,
          orElse: () => null,
        );
        final key = _rowKey(
          StoryMemoryTable.characterState,
          old?.id ?? 'state_${operation.id}',
        );
        return (key: key, row: old);
      case StoryMemoryOperationType.upsertRelationship:
        final key = _rowKey(StoryMemoryTable.relationship, operation.id!);
        return (key: key, row: rows[key]);
      case StoryMemoryOperationType.appendEvent:
        final id = operation.row!['eventId'] as String;
        final key = _rowKey(StoryMemoryTable.event, id);
        return (key: key, row: rows[key]);
      case StoryMemoryOperationType.appendPlotSummary:
        final id = operation.row!['summaryId'] as String;
        final key = _rowKey(StoryMemoryTable.plotSummary, id);
        return (key: key, row: rows[key]);
    }
  }

  StoryMemorySnapshot _snapshotFromExtensionRows(
    String conversationId,
    List<BusinessExtensionEntityValue> rows,
  ) {
    final storyRows = <StoryMemoryRow>[];
    final checkpoints = <StoryMemoryCheckpoint>[];
    final patches = <StoryMemoryPatchLog>[];
    final pendingPatches = <StoryMemoryPendingPatch>[];
    for (final row in rows) {
      if (row.kind == patchKind) {
        patches.add(StoryMemoryPatchLog.fromExtension(row));
        continue;
      }
      if (row.kind == checkpointKind) {
        checkpoints.add(StoryMemoryCheckpoint.fromExtension(row));
        continue;
      }
      if (row.kind == pendingPatchKind) {
        pendingPatches.add(StoryMemoryPendingPatch.fromExtension(row));
        continue;
      }
      StoryMemoryTable? table;
      for (final candidate in StoryMemoryTable.values) {
        if (candidate.wireName == row.kind) {
          table = candidate;
          break;
        }
      }
      if (table == null) continue;
      storyRows.add(StoryMemoryRow.fromExtension(row));
    }
    storyRows.sort((a, b) {
      final byTable = a.table.index.compareTo(b.table.index);
      return byTable != 0
          ? byTable
          : a.sortOrder == b.sortOrder
          ? a.id.compareTo(b.id)
          : a.sortOrder.compareTo(b.sortOrder);
    });
    checkpoints.sort((a, b) => a.startOrder.compareTo(b.startOrder));
    patches.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    pendingPatches.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return StoryMemorySnapshot(
      conversationId: conversationId,
      rows: storyRows,
      checkpoints: checkpoints,
      patches: patches,
      pendingPatches: pendingPatches,
    );
  }

  StoryMemoryCoverage _inspectCoverage(
    StoryMemorySnapshot snapshot,
    List<StoryMemorySourceItem> source,
  ) {
    if (source.isEmpty) {
      return const StoryMemoryCoverage(
        coveredEndOrder: -1,
        hasHole: false,
        staleFromOrder: null,
        validCheckpoints: <StoryMemoryCheckpoint>[],
      );
    }
    final sorted =
        snapshot.checkpoints
            .where((checkpoint) => checkpoint.status == 'valid')
            .toList()
          ..sort((a, b) => a.startOrder.compareTo(b.startOrder));
    var expected = source.first.order;
    var coveredEnd = -1;
    var hasHole = false;
    int? staleFrom;
    final validPrefix = <StoryMemoryCheckpoint>[];
    for (final checkpoint in sorted) {
      if (checkpoint.startOrder < expected) {
        // Overlapping or duplicate valid ranges are ambiguous after a
        // restore/manual edit. Do not let their summaries enter a request;
        // rebuilding from the overlapping checkpoint is the conservative
        // recovery path.
        staleFrom = checkpoint.startOrder;
        hasHole = true;
        break;
      }
      if (checkpoint.startOrder != expected) {
        hasHole = true;
        break;
      }
      final range = StoryMemorySource.range(
        source,
        startOrder: checkpoint.startOrder,
        endOrder: checkpoint.endOrder,
      );
      final producingPatch = snapshot.patches
          .where((patch) => patch.id == checkpoint.patchId)
          .firstOrNull;
      final expectedSourceIds = [for (final item in range) item.message.id];
      final summaryExists = snapshot.rowsFor(StoryMemoryTable.plotSummary).any((
        row,
      ) {
        final sourceIds = row.data['sourceMessageIds'];
        final sourceIdsMatch =
            sourceIds is List &&
            sourceIds.length == expectedSourceIds.length &&
            sourceIds.asMap().entries.every(
              (entry) => entry.value == expectedSourceIds[entry.key],
            );
        final isSummaryForRange =
            row.data['sourceStartOrder'] == checkpoint.startOrder &&
            row.data['sourceEndOrder'] == checkpoint.endOrder &&
            row.data['sourceDigest'] == checkpoint.selectedVersionDigest &&
            sourceIdsMatch;
        if (!isSummaryForRange) return false;
        final sourcePatchId = row.data['sourcePatchId'];
        if (sourcePatchId == checkpoint.patchId) return true;
        // Older backups may not carry row provenance, but a checkpoint is
        // still safe only when its patch log names this exact summary row.
        return producingPatch?.afterRows.any(
              (candidate) =>
                  candidate.table == StoryMemoryTable.plotSummary &&
                  candidate.id == row.id,
            ) ==
            true;
      });
      if (range.isEmpty ||
          range.first.order != checkpoint.startOrder ||
          range.last.order != checkpoint.endOrder ||
          range.length != checkpoint.endOrder - checkpoint.startOrder + 1 ||
          StoryMemorySource.digest(range) != checkpoint.selectedVersionDigest ||
          !summaryExists) {
        staleFrom = checkpoint.startOrder;
        hasHole = true;
        break;
      }
      validPrefix.add(checkpoint);
      coveredEnd = checkpoint.endOrder;
      expected = checkpoint.endOrder + 1;
    }
    if (coveredEnd < 0 && sorted.isNotEmpty && staleFrom == null) {
      final first = sorted.first;
      if (first.startOrder == source.first.order) {
        staleFrom = first.startOrder;
        hasHole = true;
      }
    }
    return StoryMemoryCoverage(
      coveredEndOrder: coveredEnd,
      hasHole: hasHole,
      staleFromOrder: staleFrom,
      validCheckpoints: List.unmodifiable(validPrefix),
    );
  }

  static void _validateSourceWindow(
    StoryMemoryPatch patch,
    List<StoryMemorySourceItem> source,
  ) {
    var expectedOrder = source.isEmpty ? 0 : source.first.order;
    final sourceIds = <String>{};
    for (final item in source) {
      if (item.message.conversationId != patch.conversationId) {
        throw StoryMemoryValidationException(
          'story_source_conversation',
          item.message.id,
        );
      }
      if (item.order != expectedOrder || !sourceIds.add(item.message.id)) {
        throw const StoryMemoryValidationException('story_source_order');
      }
      expectedOrder++;
    }
    final range = StoryMemorySource.range(
      source,
      startOrder: patch.sourceStartOrder,
      endOrder: patch.sourceEndOrder,
    );
    if (range.isEmpty ||
        range.first.order != patch.sourceStartOrder ||
        range.last.order != patch.sourceEndOrder ||
        StoryMemorySource.digest(range) != patch.sourceDigest) {
      throw const StoryMemoryValidationException('story_source_digest');
    }
    final summary = patch.operations.where(
      (operation) =>
          operation.type == StoryMemoryOperationType.appendPlotSummary,
    );
    if (summary.length != 1) {
      throw const StoryMemoryValidationException('story_summary_required');
    }
    final ids = summary.first.row?['sourceMessageIds'];
    final expectedIds = [for (final item in range) item.message.id];
    if (ids is! List ||
        ids.length != expectedIds.length ||
        ids.asMap().entries.any(
          (entry) => entry.value != expectedIds[entry.key],
        )) {
      throw const StoryMemoryValidationException('story_source_ids');
    }
  }

  static void _validateGlobalIds(
    StoryMemoryPatch patch,
    List<BusinessExtensionEntityValue> allExtensionRows,
    String conversationId,
  ) {
    // ExtensionEntityRows is keyed by (kind, id), not owner_id. A model is
    // therefore never allowed to overwrite another conversation's row.
    // Existing rows in this conversation are the only safe reuse case.
    final touched = <String>{};
    for (final operation in patch.operations) {
      final identity = switch (operation.type) {
        StoryMemoryOperationType.upsertCharacter =>
          '${StoryMemoryTable.character.wireName}\u0000${operation.id}',
        StoryMemoryOperationType.upsertCharacterState =>
          '${StoryMemoryTable.characterState.wireName}\u0000state_${operation.id}',
        StoryMemoryOperationType.upsertRelationship =>
          '${StoryMemoryTable.relationship.wireName}\u0000${operation.id}',
        StoryMemoryOperationType.appendEvent =>
          '${StoryMemoryTable.event.wireName}\u0000${operation.row?['eventId']}',
        StoryMemoryOperationType.appendPlotSummary =>
          '${StoryMemoryTable.plotSummary.wireName}\u0000${operation.row?['summaryId']}',
      };
      if (!touched.add(identity)) {
        throw StoryMemoryValidationException('story_duplicate_id', identity);
      }
      final parts = identity.split('\u0000');
      final existing = allExtensionRows.where(
        (row) => row.kind == parts[0] && row.id == parts[1],
      );
      if (existing.any((row) => row.ownerId != conversationId)) {
        throw StoryMemoryValidationException('story_id_collision', identity);
      }
    }
  }

  void _applyOperation(
    Map<String, StoryMemoryRow> rows,
    StoryMemoryOperation operation, {
    required List<String> sourceIds,
    required int sourceStartOrder,
    required int sourceEndOrder,
    required String sourceDigest,
    required DateTime now,
    required String patchId,
    required Set<String> validPatchIds,
  }) {
    final fields = operation.fields;
    switch (operation.type) {
      case StoryMemoryOperationType.upsertCharacter:
        final id = operation.id!;
        final key = _rowKey(StoryMemoryTable.character, id);
        final old = rows[key];
        final mergeBase = _isCurrentRow(old, validPatchIds) ? old : null;
        final data = <String, dynamic>{
          ...?mergeBase?.data,
          ...fields!,
          'characterId': id,
          'sourceMessageIds': sourceIds,
          'sourceStartOrder': sourceStartOrder,
          'sourceEndOrder': sourceEndOrder,
          'sourceDigest': sourceDigest,
          'sourcePatchId': patchId,
          'updatedAt': now.microsecondsSinceEpoch,
        };
        rows[key] = StoryMemoryRow(
          table: StoryMemoryTable.character,
          id: id,
          sortOrder: old?.sortOrder ?? sourceEndOrder,
          ownerId: old?.ownerId,
          data: data,
        );
      case StoryMemoryOperationType.upsertCharacterState:
        final characterId = operation.id!;
        final old = rows.values.cast<StoryMemoryRow?>().firstWhere(
          (row) =>
              row?.table == StoryMemoryTable.characterState &&
              row?.data['characterId'] == characterId,
          orElse: () => null,
        );
        final mergeBase = _isCurrentRow(old, validPatchIds) ? old : null;
        final id = old?.id ?? 'state_$characterId';
        final key = _rowKey(StoryMemoryTable.characterState, id);
        final data = <String, dynamic>{
          ...?mergeBase?.data,
          ...fields!,
          'characterId': characterId,
          'sourceMessageIds': sourceIds,
          'sourceStartOrder': sourceStartOrder,
          'sourceEndOrder': sourceEndOrder,
          'sourceDigest': sourceDigest,
          'sourcePatchId': patchId,
          'updatedAt': now.microsecondsSinceEpoch,
        };
        rows[key] = StoryMemoryRow(
          table: StoryMemoryTable.characterState,
          id: id,
          sortOrder: sourceEndOrder,
          ownerId: old?.ownerId,
          data: data,
        );
      case StoryMemoryOperationType.upsertRelationship:
        final id = operation.id!;
        final key = _rowKey(StoryMemoryTable.relationship, id);
        final old = rows[key];
        final mergeBase = _isCurrentRow(old, validPatchIds) ? old : null;
        final data = <String, dynamic>{
          ...?mergeBase?.data,
          ...fields!,
          'relationshipId': id,
          'sourceMessageIds': sourceIds,
          'sourceStartOrder': sourceStartOrder,
          'sourceEndOrder': sourceEndOrder,
          'sourceDigest': sourceDigest,
          'sourcePatchId': patchId,
          'updatedAt': now.microsecondsSinceEpoch,
        };
        rows[key] = StoryMemoryRow(
          table: StoryMemoryTable.relationship,
          id: id,
          sortOrder: sourceEndOrder,
          ownerId: old?.ownerId,
          data: data,
        );
      case StoryMemoryOperationType.appendEvent:
        final raw = operation.row!;
        final id = raw['eventId'] as String;
        final data = <String, dynamic>{
          ...raw,
          'sourceStartOrder': sourceStartOrder,
          'sourceEndOrder': sourceEndOrder,
          'sourceDigest': sourceDigest,
          'sourceMessageIds': sourceIds,
          'sourcePatchId': patchId,
          'updatedAt': now.microsecondsSinceEpoch,
        };
        rows[_rowKey(StoryMemoryTable.event, id)] = StoryMemoryRow(
          table: StoryMemoryTable.event,
          id: id,
          sortOrder: sourceEndOrder,
          data: data,
        );
      case StoryMemoryOperationType.appendPlotSummary:
        final raw = operation.row!;
        final id = raw['summaryId'] as String;
        final data = <String, dynamic>{
          ...raw,
          'sourceStartOrder': sourceStartOrder,
          'sourceEndOrder': sourceEndOrder,
          'sourceDigest': sourceDigest,
          'sourceMessageIds': sourceIds,
          'sourcePatchId': patchId,
          'createdAt': now.microsecondsSinceEpoch,
        };
        rows[_rowKey(StoryMemoryTable.plotSummary, id)] = StoryMemoryRow(
          table: StoryMemoryTable.plotSummary,
          id: id,
          sortOrder: sourceEndOrder,
          data: data,
        );
    }
  }

  Future<void> _recordFailure({
    required String patchId,
    required StoryMemoryPatch patch,
    required String error,
  }) async {
    try {
      final now = DateTime.now().toUtc();
      final log = StoryMemoryPatchLog(
        id: patchId,
        conversationId: patch.conversationId,
        sourceStartOrder: patch.sourceStartOrder,
        sourceEndOrder: patch.sourceEndOrder,
        sourceDigest: patch.sourceDigest,
        status: 'failed',
        createdAt: now,
        error: error,
        operations: [
          for (final operation in patch.operations) operation.toJson(),
        ],
      );
      await businessRepository.upsertExtensionEntity(
        BusinessExtensionEntityValue(
          kind: patchKind,
          id: patchId,
          sortOrder: patch.sourceEndOrder,
          ownerId: patch.conversationId,
          payload: jsonEncode(log.toJson()),
        ),
      );
    } catch (_) {
      // Audit persistence must never turn a fail-open extraction failure into
      // a chat failure.
    }
  }

  static BusinessExtensionEntityValue _extensionRow(
    StoryMemoryRow row,
    String conversationId,
  ) => BusinessExtensionEntityValue(
    kind: row.table.wireName,
    id: row.id,
    sortOrder: row.sortOrder,
    ownerId: conversationId,
    payload: jsonEncode(row.data),
  );

  static String _rowKey(StoryMemoryTable table, String id) =>
      '${table.wireName}\u0000$id';

  static void _validateManualIdentity(
    StoryMemoryTable table,
    String id,
    Map<String, dynamic> data,
  ) {
    if (table == StoryMemoryTable.characterState) {
      final characterId = data['characterId'];
      if (characterId is! String || characterId.trim().isEmpty) {
        throw ArgumentError.value(data, 'data');
      }
      return;
    }
    final key = switch (table) {
      StoryMemoryTable.character => 'characterId',
      StoryMemoryTable.relationship => 'relationshipId',
      StoryMemoryTable.event => 'eventId',
      StoryMemoryTable.plotSummary => 'summaryId',
      StoryMemoryTable.characterState => throw StateError(
        'story_manual_identity',
      ),
    };
    if (data[key] != id) throw ArgumentError.value(data, 'data');
  }

  static bool _sameRow(StoryMemoryRow left, StoryMemoryRow right) =>
      left.table == right.table &&
      left.id == right.id &&
      left.sortOrder == right.sortOrder &&
      jsonEncode(left.data) == jsonEncode(right.data);

  static bool _isCurrentRow(StoryMemoryRow? row, Set<String> validPatchIds) {
    if (row == null) return false;
    final patchId = row.data['sourcePatchId'];
    return patchId is! String || validPatchIds.contains(patchId);
  }

  static String _requireConversationId(String value) {
    final id = value.trim();
    if (id.isEmpty) throw ArgumentError.value(value, 'conversationId');
    return id;
  }

  static void _validateJsonObject(Map<String, dynamic> data) {
    try {
      final encoded = jsonEncode(data);
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) throw const FormatException('story_row');
    } on Object {
      throw const FormatException('story_row');
    }
  }
}
