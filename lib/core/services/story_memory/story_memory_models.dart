import 'dart:convert';

import '../../database/business_data.dart';

/// The fixed story-memory tables shipped in v1.
enum StoryMemoryTable {
  character('story_character'),
  characterState('story_character_state'),
  relationship('story_relationship'),
  event('story_event'),
  plotSummary('story_plot_summary');

  const StoryMemoryTable(this.wireName);

  final String wireName;

  static StoryMemoryTable fromWire(Object? raw) {
    final value = (raw ?? '').toString();
    for (final table in values) {
      if (table.wireName == value) return table;
    }
    throw FormatException('story_table:$value');
  }
}

enum StoryMemoryOperationType {
  upsertCharacter('upsertCharacter'),
  upsertCharacterState('upsertCharacterState'),
  upsertRelationship('upsertRelationship'),
  appendEvent('appendEvent'),
  appendPlotSummary('appendPlotSummary');

  const StoryMemoryOperationType(this.wireName);

  final String wireName;

  static StoryMemoryOperationType fromWire(Object? raw) {
    final value = (raw ?? '').toString();
    for (final operation in values) {
      if (operation.wireName == value) return operation;
    }
    throw FormatException('story_operation:$value');
  }
}

/// A decoded row from one of the five fixed story tables.
final class StoryMemoryRow {
  StoryMemoryRow({
    required this.table,
    required this.id,
    required Map<String, dynamic> data,
    this.sortOrder = 0,
    this.ownerId,
  }) : data = Map<String, dynamic>.unmodifiable(data);

  factory StoryMemoryRow.fromExtension(BusinessExtensionEntityValue row) {
    final decoded = jsonDecode(row.payload);
    if (decoded is! Map) throw FormatException('story_payload:${row.id}');
    return StoryMemoryRow(
      table: StoryMemoryTable.fromWire(row.kind),
      id: row.id,
      sortOrder: row.sortOrder,
      ownerId: row.ownerId,
      data: decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  factory StoryMemoryRow.fromJson(Object raw) {
    if (raw is! Map) throw const FormatException('story_row_json');
    final map = raw.map((key, value) => MapEntry(key.toString(), value));
    final table = StoryMemoryTable.fromWire(map['table']);
    final id = map['id'];
    final sortOrder = map['sortOrder'];
    final data = map['data'];
    if (id is! String ||
        id.trim().isEmpty ||
        sortOrder is! int ||
        sortOrder < 0 ||
        data is! Map) {
      throw const FormatException('story_row_json');
    }
    return StoryMemoryRow(
      table: table,
      id: id,
      sortOrder: sortOrder,
      ownerId: map['ownerId'] is String ? map['ownerId'] as String : null,
      data: data.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  final StoryMemoryTable table;
  final String id;
  final int sortOrder;
  final String? ownerId;
  final Map<String, dynamic> data;

  String? get stringId => data['characterId'] is String
      ? data['characterId'] as String
      : data['eventId'] is String
      ? data['eventId'] as String
      : data['summaryId'] is String
      ? data['summaryId'] as String
      : null;

  StoryMemoryRow copyWith({
    StoryMemoryTable? table,
    String? id,
    int? sortOrder,
    String? ownerId,
    Map<String, dynamic>? data,
  }) => StoryMemoryRow(
    table: table ?? this.table,
    id: id ?? this.id,
    sortOrder: sortOrder ?? this.sortOrder,
    ownerId: ownerId ?? this.ownerId,
    data: data ?? this.data,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'table': table.wireName,
    'id': id,
    'sortOrder': sortOrder,
    if (ownerId != null) 'ownerId': ownerId,
    'data': data,
  };
}

final class StoryMemoryCheckpoint {
  const StoryMemoryCheckpoint({
    required this.id,
    required this.conversationId,
    required this.startOrder,
    required this.endOrder,
    required this.selectedVersionDigest,
    required this.patchId,
    required this.status,
    required this.createdAt,
  });

  factory StoryMemoryCheckpoint.fromExtension(
    BusinessExtensionEntityValue row,
  ) {
    final decoded = jsonDecode(row.payload);
    if (decoded is! Map) throw FormatException('story_checkpoint:${row.id}');
    final map = decoded.map((key, value) => MapEntry(key.toString(), value));
    final start = map['startOrder'];
    final end = map['endOrder'];
    final createdAt = map['createdAt'];
    final conversationId = map['conversationId'];
    final digest = map['selectedVersionDigest'];
    final patchId = map['patchId'];
    final status = map['status'];
    if (conversationId is! String ||
        start is! int ||
        end is! int ||
        createdAt is! int ||
        digest is! String ||
        patchId is! String ||
        status is! String) {
      throw FormatException('story_checkpoint:${row.id}');
    }
    return StoryMemoryCheckpoint(
      id: row.id,
      conversationId: conversationId,
      startOrder: start,
      endOrder: end,
      selectedVersionDigest: digest,
      patchId: patchId,
      status: status,
      createdAt: DateTime.fromMicrosecondsSinceEpoch(createdAt, isUtc: true),
    );
  }

  final String id;
  final String conversationId;
  final int startOrder;
  final int endOrder;
  final String selectedVersionDigest;
  final String patchId;
  final String status;
  final DateTime createdAt;

  bool get isValid => status == 'valid';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'checkpointId': id,
    'conversationId': conversationId,
    'startOrder': startOrder,
    'endOrder': endOrder,
    'selectedVersionDigest': selectedVersionDigest,
    'patchId': patchId,
    'status': status,
    'createdAt': createdAt.toUtc().microsecondsSinceEpoch,
  };
}

final class StoryMemoryPatchLog {
  const StoryMemoryPatchLog({
    required this.id,
    required this.conversationId,
    required this.sourceStartOrder,
    required this.sourceEndOrder,
    required this.sourceDigest,
    required this.status,
    required this.createdAt,
    required this.operations,
    this.manual = false,
    this.error,
    this.beforeRows = const <StoryMemoryRow>[],
    this.afterRows = const <StoryMemoryRow>[],
    this.createdRows = const <StoryMemoryRow>[],
    this.deletedRows = const <StoryMemoryRow>[],
  });

  factory StoryMemoryPatchLog.fromExtension(BusinessExtensionEntityValue row) {
    final decoded = jsonDecode(row.payload);
    if (decoded is! Map) throw FormatException('story_patch:${row.id}');
    final map = decoded.map((key, value) => MapEntry(key.toString(), value));
    final operations = map['operations'];
    final start = map['sourceStartOrder'];
    final end = map['sourceEndOrder'];
    final digest = map['sourceDigest'];
    final conversationId = map['conversationId'];
    final status = map['status'];
    final createdAt = map['createdAt'];
    final manual = map['manual'] == true;
    if (conversationId is! String ||
        (start != null && start is! int) ||
        (end != null && end is! int) ||
        (digest != null && digest is! String) ||
        status is! String ||
        createdAt is! int ||
        operations is! List ||
        (!manual && (start == null || end == null || digest == null))) {
      throw FormatException('story_patch:${row.id}');
    }
    return StoryMemoryPatchLog(
      id: row.id,
      conversationId: conversationId,
      sourceStartOrder: start as int?,
      sourceEndOrder: end as int?,
      sourceDigest: digest as String?,
      status: status,
      createdAt: DateTime.fromMicrosecondsSinceEpoch(createdAt, isUtc: true),
      manual: manual,
      error: map['error'] is String ? map['error'] as String : null,
      operations: List<Object?>.unmodifiable(operations),
      beforeRows: _decodeRows(map['beforeRows'], row.id),
      afterRows: _decodeRows(map['afterRows'], row.id),
      createdRows: _decodeRows(map['createdRows'], row.id),
      deletedRows: _decodeRows(map['deletedRows'], row.id),
    );
  }

  static List<StoryMemoryRow> _decodeRows(Object? raw, String patchId) {
    if (raw == null) return const <StoryMemoryRow>[];
    if (raw is! List) throw FormatException('story_patch_rows:$patchId');
    return List<StoryMemoryRow>.unmodifiable(
      raw.map((value) => StoryMemoryRow.fromJson(value)),
    );
  }

  final String id;
  final String conversationId;
  final int? sourceStartOrder;
  final int? sourceEndOrder;
  final String? sourceDigest;
  final String status;
  final DateTime createdAt;
  final bool manual;
  final String? error;
  final List<Object?> operations;
  final List<StoryMemoryRow> beforeRows;
  final List<StoryMemoryRow> afterRows;
  final List<StoryMemoryRow> createdRows;
  final List<StoryMemoryRow> deletedRows;

  StoryMemoryPatchLog copyWith({String? status, String? error}) =>
      StoryMemoryPatchLog(
        id: id,
        conversationId: conversationId,
        sourceStartOrder: sourceStartOrder,
        sourceEndOrder: sourceEndOrder,
        sourceDigest: sourceDigest,
        status: status ?? this.status,
        createdAt: createdAt,
        manual: manual,
        operations: operations,
        error: error ?? this.error,
        beforeRows: beforeRows,
        afterRows: afterRows,
        createdRows: createdRows,
        deletedRows: deletedRows,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'patchId': id,
    'conversationId': conversationId,
    if (sourceStartOrder != null) 'sourceStartOrder': sourceStartOrder,
    if (sourceEndOrder != null) 'sourceEndOrder': sourceEndOrder,
    if (sourceDigest != null) 'sourceDigest': sourceDigest,
    'status': status,
    'createdAt': createdAt.toUtc().microsecondsSinceEpoch,
    if (manual) 'manual': true,
    if (error != null) 'error': error,
    'operations': operations,
    'beforeRows': [for (final row in beforeRows) row.toJson()],
    'afterRows': [for (final row in afterRows) row.toJson()],
    'createdRows': [for (final row in createdRows) row.toJson()],
    'deletedRows': [for (final row in deletedRows) row.toJson()],
  };
}

/// A model-generated patch waiting for explicit user approval.
///
/// Pending patches are durable so an app restart cannot silently lose a
/// reviewable change. They are kept in the same extension snapshot as the
/// committed patch log and are never eligible for context injection.
final class StoryMemoryPendingPatch {
  const StoryMemoryPendingPatch({
    required this.id,
    required this.conversationId,
    required this.patch,
    required this.status,
    required this.createdAt,
    this.error,
    this.appliedPatchId,
  });

  factory StoryMemoryPendingPatch.fromExtension(
    BusinessExtensionEntityValue row,
  ) {
    final decoded = jsonDecode(row.payload);
    if (decoded is! Map) throw FormatException('story_pending:${row.id}');
    final map = decoded.map((key, value) => MapEntry(key.toString(), value));
    final conversationId = map['conversationId'];
    final status = map['status'];
    final createdAt = map['createdAt'];
    final rawPatch = map['patch'];
    if (conversationId is! String ||
        conversationId.trim().isEmpty ||
        status is! String ||
        !const {'pending', 'applied', 'discarded', 'stale'}.contains(status) ||
        createdAt is! int ||
        rawPatch is! Map) {
      throw FormatException('story_pending:${row.id}');
    }
    final patch = StoryMemoryPatch.parse(rawPatch);
    if (patch.conversationId != conversationId) {
      throw FormatException('story_pending_conversation:${row.id}');
    }
    return StoryMemoryPendingPatch(
      id: row.id,
      conversationId: conversationId,
      patch: patch,
      status: status,
      createdAt: DateTime.fromMicrosecondsSinceEpoch(createdAt, isUtc: true),
      error: map['error'] is String ? map['error'] as String : null,
      appliedPatchId: map['appliedPatchId'] is String
          ? map['appliedPatchId'] as String
          : null,
    );
  }

  final String id;
  final String conversationId;
  final StoryMemoryPatch patch;
  final String status;
  final DateTime createdAt;
  final String? error;
  final String? appliedPatchId;

  bool get isPending => status == 'pending';

  StoryMemoryPendingPatch copyWith({
    String? status,
    String? error,
    String? appliedPatchId,
  }) => StoryMemoryPendingPatch(
    id: id,
    conversationId: conversationId,
    patch: patch,
    status: status ?? this.status,
    createdAt: createdAt,
    error: error ?? this.error,
    appliedPatchId: appliedPatchId ?? this.appliedPatchId,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'pendingId': id,
    'conversationId': conversationId,
    'status': status,
    'createdAt': createdAt.toUtc().microsecondsSinceEpoch,
    'patch': patch.toJson(),
    if (error != null) 'error': error,
    if (appliedPatchId != null) 'appliedPatchId': appliedPatchId,
  };
}

final class StoryMemorySnapshot {
  StoryMemorySnapshot({
    required this.conversationId,
    required List<StoryMemoryRow> rows,
    required List<StoryMemoryCheckpoint> checkpoints,
    required List<StoryMemoryPatchLog> patches,
    List<StoryMemoryPendingPatch> pendingPatches = const [],
  }) : rows = List<StoryMemoryRow>.unmodifiable(rows),
       checkpoints = List<StoryMemoryCheckpoint>.unmodifiable(checkpoints),
       patches = List<StoryMemoryPatchLog>.unmodifiable(patches),
       pendingPatches = List<StoryMemoryPendingPatch>.unmodifiable(
         pendingPatches,
       );

  final String conversationId;
  final List<StoryMemoryRow> rows;
  final List<StoryMemoryCheckpoint> checkpoints;
  final List<StoryMemoryPatchLog> patches;
  final List<StoryMemoryPendingPatch> pendingPatches;

  List<StoryMemoryRow> rowsFor(StoryMemoryTable table) => [
    for (final row in rows)
      if (row.table == table) row,
  ];

  StoryMemoryRow? rowById(StoryMemoryTable table, String id) {
    for (final row in rows) {
      if (row.table == table && row.id == id) return row;
    }
    return null;
  }

  StoryMemoryRow? stateForCharacter(String characterId) {
    for (final row in rowsFor(StoryMemoryTable.characterState)) {
      if (row.data['characterId'] == characterId) return row;
    }
    return null;
  }

  /// Rows that are safe for a new model patch to use as authoritative facts.
  ///
  /// Automatic rows produced by a stale checkpoint remain in the database for
  /// audit and possible manual recovery, but must not become the base of a
  /// rebuild. Rows without provenance are explicit manual rows and remain
  /// eligible.
  List<StoryMemoryRow> get currentRows {
    final validPatchIds = checkpoints
        .where((checkpoint) => checkpoint.status == 'valid')
        .map((checkpoint) => checkpoint.patchId)
        .toSet();
    return [
      for (final row in rows)
        if (!row.data.containsKey('sourcePatchId') ||
            (row.data['sourcePatchId'] is String &&
                validPatchIds.contains(row.data['sourcePatchId'])))
          row,
    ];
  }

  Map<String, Object> toPromptJson({bool currentOnly = false}) {
    final promptRows = currentOnly ? currentRows : rows;
    List<Map<String, dynamic>> dataFor(StoryMemoryTable table) => [
      for (final row in promptRows)
        if (row.table == table) row.data,
    ];
    return <String, Object>{
      'characters': dataFor(StoryMemoryTable.character),
      'characterStates': dataFor(StoryMemoryTable.characterState),
      'relationships': dataFor(StoryMemoryTable.relationship),
      'events': dataFor(StoryMemoryTable.event),
      'plotSummaries': dataFor(StoryMemoryTable.plotSummary),
    };
  }

  bool get isEmpty => rows.isEmpty;
}

final class StoryMemoryOperation {
  const StoryMemoryOperation({
    required this.type,
    this.id,
    this.fields,
    this.row,
  });

  final StoryMemoryOperationType type;
  final String? id;
  final Map<String, dynamic>? fields;
  final Map<String, dynamic>? row;

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{'op': type.wireName};
    if (id != null) {
      final key = switch (type) {
        StoryMemoryOperationType.upsertRelationship => 'relationshipId',
        _ => 'characterId',
      };
      result[key] = id;
    }
    if (fields != null) result['fields'] = fields;
    if (row != null) result['row'] = row;
    return result;
  }
}

final class StoryMemoryPatch {
  const StoryMemoryPatch({
    required this.schemaVersion,
    required this.conversationId,
    required this.sourceStartOrder,
    required this.sourceEndOrder,
    required this.sourceDigest,
    required this.operations,
  });

  static const int currentSchemaVersion = 1;
  static const int maxOperations = 64;
  static const int maxResponseBytes = 256 * 1024;
  static final RegExp digestPattern = RegExp(r'^[0-9a-fA-F]{64}$');

  factory StoryMemoryPatch.parse(Object raw) {
    final Object? decoded;
    if (raw is String) {
      if (utf8.encode(raw).length > maxResponseBytes) {
        throw const FormatException('story_patch_too_large');
      }
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        throw const FormatException('story_patch_json');
      }
    } else {
      decoded = raw;
    }
    if (decoded is! Map) throw const FormatException('story_patch_root');
    final map = decoded.map((key, value) => MapEntry(key.toString(), value));
    _exactKeys(map, const {
      'schemaVersion',
      'conversationId',
      'sourceStartOrder',
      'sourceEndOrder',
      'sourceDigest',
      'operations',
    });
    final schemaVersion = map['schemaVersion'];
    final conversationId = map['conversationId'];
    final start = map['sourceStartOrder'];
    final end = map['sourceEndOrder'];
    final digest = map['sourceDigest'];
    final operations = map['operations'];
    if (schemaVersion != currentSchemaVersion ||
        conversationId is! String ||
        conversationId.trim().isEmpty ||
        start is! int ||
        start < 0 ||
        end is! int ||
        end < start ||
        digest is! String ||
        !digestPattern.hasMatch(digest) ||
        operations is! List ||
        operations.isEmpty ||
        operations.length > maxOperations) {
      throw const FormatException('story_patch_fields');
    }
    return StoryMemoryPatch(
      schemaVersion: schemaVersion as int,
      conversationId: conversationId,
      sourceStartOrder: start,
      sourceEndOrder: end,
      sourceDigest: digest.toLowerCase(),
      operations: [for (final item in operations) _parseOperation(item)],
    );
  }

  final int schemaVersion;
  final String conversationId;
  final int sourceStartOrder;
  final int sourceEndOrder;
  final String sourceDigest;
  final List<StoryMemoryOperation> operations;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schemaVersion': schemaVersion,
    'conversationId': conversationId,
    'sourceStartOrder': sourceStartOrder,
    'sourceEndOrder': sourceEndOrder,
    'sourceDigest': sourceDigest,
    'operations': [for (final operation in operations) operation.toJson()],
  };

  String encode() => jsonEncode(toJson());

  static StoryMemoryOperation _parseOperation(Object? raw) {
    if (raw is! Map) throw const FormatException('story_patch_operation');
    final map = raw.map((key, value) => MapEntry(key.toString(), value));
    final type = StoryMemoryOperationType.fromWire(map['op']);
    final usesRow =
        type == StoryMemoryOperationType.appendEvent ||
        type == StoryMemoryOperationType.appendPlotSummary;
    final allowed = usesRow
        ? const {'op', 'row'}
        : type == StoryMemoryOperationType.upsertRelationship
        ? const {'op', 'relationshipId', 'fields'}
        : const {'op', 'characterId', 'fields'};
    _exactKeys(map, allowed);
    if (usesRow) {
      final row = map['row'];
      if (row is! Map) throw const FormatException('story_patch_row');
      return StoryMemoryOperation(
        type: type,
        row: row.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    final id = type == StoryMemoryOperationType.upsertRelationship
        ? map['relationshipId']
        : map['characterId'];
    final fields = map['fields'];
    if (id is! String || id.trim().isEmpty || fields is! Map) {
      throw const FormatException('story_patch_fields');
    }
    return StoryMemoryOperation(
      type: type,
      id: id,
      fields: fields.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  static void _exactKeys(Map<String, dynamic> map, Set<String> allowed) {
    if (map.length != allowed.length ||
        map.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('story_patch_unknown_field');
    }
  }
}
