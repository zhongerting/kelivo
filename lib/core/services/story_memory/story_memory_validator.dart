import 'story_memory_models.dart';

final class StoryMemoryValidationException implements Exception {
  const StoryMemoryValidationException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail == null ? code : '$code:$detail';
}

/// Structural and semantic checks for model patches. This class deliberately
/// has no database side effects; the repository performs the final source
/// digest check and commits only after this validator succeeds.
final class StoryMemoryValidator {
  StoryMemoryValidator._();

  static const int maxFieldStringLength = 12000;
  static const int maxArrayLength = 128;
  static const int maxObjectKeys = 64;
  static const int maxDepth = 8;

  static const _characterFields = <String>{
    'name',
    'aliases',
    'identity',
    'appearance',
    'coreTraits',
    'motivation',
    'background',
    'importance',
    'sourceMessageIds',
  };
  static const _stateFields = <String>{
    'location',
    'physicalState',
    'emotionalState',
    'currentGoal',
    'knowledge',
    'possessions',
    'present',
    'effectiveAtOrder',
    'sourceMessageIds',
  };
  static const _relationshipFields = <String>{
    'fromCharacterId',
    'toCharacterId',
    'relationType',
    'attitude',
    'trust',
    'changeReason',
    'effectiveAtOrder',
    'sourceEventIds',
  };
  static const _eventFields = <String>{
    'eventId',
    'chapterOrTime',
    'participants',
    'location',
    'cause',
    'summary',
    'result',
    'consequences',
    'unresolvedClues',
    'importance',
    'sourceStartOrder',
    'sourceEndOrder',
    'sourceMessageIds',
  };
  static const _summaryFields = <String>{
    'summaryId',
    'sourceStartOrder',
    'sourceEndOrder',
    'sourceDigest',
    'sourceMessageIds',
    'summary',
    'keyEntities',
    'unresolvedThreads',
  };

  static void validatePatch(
    StoryMemoryPatch patch,
    StoryMemorySnapshot snapshot,
  ) {
    if (patch.operations.isEmpty) _fail('story_patch_empty');
    if (patch.encode().length > StoryMemoryPatch.maxResponseBytes) {
      _fail('story_patch_too_large');
    }

    final authoritativeRows = snapshot.currentRows;
    final characters = <String>{
      for (final row in authoritativeRows)
        if (row.table == StoryMemoryTable.character) row.id,
    };
    final relationshipOperations = <String>{};
    final eventIds = <String>{
      for (final row in snapshot.rowsFor(StoryMemoryTable.event)) row.id,
    };
    final summaryIds = <String>{
      for (final row in snapshot.rowsFor(StoryMemoryTable.plotSummary)) row.id,
    };
    var summaryCount = 0;
    for (final operation in patch.operations) {
      switch (operation.type) {
        case StoryMemoryOperationType.upsertCharacter:
          _validateCharacterOperation(operation, authoritativeRows, characters);
        case StoryMemoryOperationType.upsertCharacterState:
          _validateStateOperation(operation, characters);
        case StoryMemoryOperationType.upsertRelationship:
          _validateRelationshipOperation(
            operation,
            authoritativeRows,
            characters,
            relationshipOperations,
          );
        case StoryMemoryOperationType.appendEvent:
          _validateEventOperation(operation, characters, eventIds);
        case StoryMemoryOperationType.appendPlotSummary:
          summaryCount++;
          _validateSummaryOperation(operation, patch, summaryIds);
      }
    }
    if (summaryCount != 1) _fail('story_summary_required');
  }

  static void _validateCharacterOperation(
    StoryMemoryOperation operation,
    List<StoryMemoryRow> authoritativeRows,
    Set<String> characters,
  ) {
    final id = operation.id;
    final fields = operation.fields;
    if (id == null || fields == null) _fail('story_character_fields');
    _validateFieldMap(fields, _characterFields, 'story_character_field');
    if (fields.isEmpty) _fail('story_character_empty');
    final existing = _rowById(
      authoritativeRows,
      StoryMemoryTable.character,
      id,
    );
    final locked = _stringSet(existing?.data['lockedFields']);
    if (fields.keys.any(locked.contains) ||
        fields.containsKey('lockedFields')) {
      _fail('story_locked_field', id);
    }
    if (existing == null &&
        (fields['name'] is! String ||
            (fields['name'] as String).trim().isEmpty)) {
      _fail('story_character_name', id);
    }
    _validateValues(fields);
    characters.add(id);
  }

  static void _validateStateOperation(
    StoryMemoryOperation operation,
    Set<String> characters,
  ) {
    final id = operation.id;
    final fields = operation.fields;
    if (id == null || fields == null || !characters.contains(id)) {
      _fail('story_state_character', id);
    }
    _validateFieldMap(fields, _stateFields, 'story_state_field');
    if (fields.isEmpty) _fail('story_state_empty', id);
    _validateValues(fields);
  }

  static void _validateRelationshipOperation(
    StoryMemoryOperation operation,
    List<StoryMemoryRow> authoritativeRows,
    Set<String> characters,
    Set<String> relationshipOperations,
  ) {
    final id = operation.id;
    final fields = operation.fields;
    if (id == null || fields == null) _fail('story_relationship_fields');
    _validateFieldMap(fields, _relationshipFields, 'story_relationship_field');
    if (fields.isEmpty) _fail('story_relationship_empty', id);
    final from = fields['fromCharacterId'];
    final to = fields['toCharacterId'];
    final existing = _rowById(
      authoritativeRows,
      StoryMemoryTable.relationship,
      id,
    );
    final effectiveFrom = fields.containsKey('fromCharacterId')
        ? from
        : existing?.data['fromCharacterId'];
    final effectiveTo = fields.containsKey('toCharacterId')
        ? to
        : existing?.data['toCharacterId'];
    if (effectiveFrom is! String ||
        effectiveFrom.trim().isEmpty ||
        !characters.contains(effectiveFrom)) {
      _fail('story_character_reference', from.toString());
    }
    if (effectiveTo is! String ||
        effectiveTo.trim().isEmpty ||
        !characters.contains(effectiveTo)) {
      _fail('story_character_reference', to.toString());
    }
    if (!relationshipOperations.add(id)) {
      // An existing relationship may be updated once per patch. Duplicate
      // updates are ambiguous and usually indicate a malformed model reply.
      _fail('story_duplicate_relationship', id);
    }
    _validateValues(fields);
  }

  static void _validateEventOperation(
    StoryMemoryOperation operation,
    Set<String> characters,
    Set<String> eventIds,
  ) {
    final row = operation.row;
    if (row == null) _fail('story_event_row');
    _validateFieldMap(row, _eventFields, 'story_event_field');
    final id = row['eventId'];
    if (id is! String || id.trim().isEmpty || !eventIds.add(id)) {
      _fail('story_event_id');
    }
    final participants = row['participants'];
    if (participants is! List ||
        participants.any(
          (value) => value is! String || !characters.contains(value),
        )) {
      _fail('story_event_reference');
    }
    final summary = row['summary'];
    if (summary is! String || summary.trim().isEmpty) {
      _fail('story_event_summary');
    }
    _validateValues(row);
  }

  static void _validateSummaryOperation(
    StoryMemoryOperation operation,
    StoryMemoryPatch patch,
    Set<String> summaryIds,
  ) {
    final row = operation.row;
    if (row == null) _fail('story_summary_row');
    _validateFieldMap(row, _summaryFields, 'story_summary_field');
    final id = row['summaryId'];
    if (id is! String || id.trim().isEmpty || !summaryIds.add(id)) {
      _fail('story_summary_id');
    }
    if (row['sourceStartOrder'] != patch.sourceStartOrder ||
        row['sourceEndOrder'] != patch.sourceEndOrder ||
        row['sourceDigest'] != patch.sourceDigest) {
      _fail('story_summary_coverage');
    }
    final sourceIds = row['sourceMessageIds'];
    if (sourceIds is! List ||
        sourceIds.isEmpty ||
        sourceIds.any((value) => value is! String || value.trim().isEmpty)) {
      _fail('story_summary_sources');
    }
    final summary = row['summary'];
    if (summary is! String || summary.trim().isEmpty) {
      _fail('story_summary_text');
    }
    _validateValues(row);
  }

  static void _validateFieldMap(
    Map<String, dynamic> fields,
    Set<String> allowed,
    String code,
  ) {
    if (fields.keys.any((key) => !allowed.contains(key))) {
      _fail(code);
    }
  }

  static void _validateValues(Map<String, dynamic> values) {
    for (final value in values.values) {
      _validateValue(value, 0);
    }
  }

  static void _validateValue(Object? value, int depth) {
    if (depth > maxDepth) _fail('story_value_depth');
    if (value == null || value is bool || value is num) return;
    if (value is String) {
      if (value.length > maxFieldStringLength) _fail('story_value_length');
      return;
    }
    if (value is List) {
      if (value.length > maxArrayLength) _fail('story_value_array');
      for (final item in value) {
        _validateValue(item, depth + 1);
      }
      return;
    }
    if (value is Map) {
      if (value.length > maxObjectKeys) _fail('story_value_object');
      for (final entry in value.entries) {
        if (entry.key is! String) _fail('story_value_key');
        _validateValue(entry.value, depth + 1);
      }
      return;
    }
    _fail('story_value_type');
  }

  static Set<String> _stringSet(Object? raw) {
    if (raw is! List) return <String>{};
    return {
      for (final value in raw)
        if (value is String) value,
    };
  }

  static StoryMemoryRow? _rowById(
    Iterable<StoryMemoryRow> rows,
    StoryMemoryTable table,
    String id,
  ) {
    for (final row in rows) {
      if (row.table == table && row.id == id) return row;
    }
    return null;
  }

  static Never _fail(String code, [String? detail]) {
    throw StoryMemoryValidationException(code, detail);
  }
}
