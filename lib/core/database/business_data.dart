typedef BusinessEntityRowIds = Map<String, List<String>>;

/// A row stored in the schema-less extension table.
///
/// Extension rows are deliberately kept outside [BusinessEntityKind]. The
/// latter describes the legacy key/value projection used by providers, while
/// extensions may be scoped by an arbitrary owner and are not runtime
/// preferences. The backup layer still carries them through the same
/// business snapshot so settings-only restores do not lose feature data.
final class BusinessExtensionEntityValue {
  const BusinessExtensionEntityValue({
    required this.kind,
    required this.id,
    required this.sortOrder,
    required this.payload,
    this.ownerId,
  });

  final String kind;
  final String id;
  final int sortOrder;
  final String? ownerId;
  final String payload;

  BusinessExtensionEntityValue copyWith({
    String? kind,
    String? id,
    int? sortOrder,
    String? ownerId,
    String? payload,
  }) => BusinessExtensionEntityValue(
    kind: kind ?? this.kind,
    id: id ?? this.id,
    sortOrder: sortOrder ?? this.sortOrder,
    ownerId: ownerId ?? this.ownerId,
    payload: payload ?? this.payload,
  );
}

typedef BusinessSettingsExport = ({
  Map<String, Object> settings,
  BusinessEntityRowIds entityRowIds,
});

enum BusinessEntityKind {
  assistant(sourceKey: 'assistants_v1', tableName: 'assistant_rows'),
  provider(sourceKey: 'provider_configs_v1', tableName: 'provider_rows'),
  providerGroup(
    sourceKey: 'provider_groups_v1',
    tableName: 'provider_group_rows',
  ),
  mcpServer(sourceKey: 'mcp_servers_v1', tableName: 'mcp_server_rows'),
  worldBook(sourceKey: 'world_books_v1', tableName: 'world_book_rows'),
  assistantMemory(
    sourceKey: 'assistant_memories_v1',
    tableName: 'assistant_memory_rows',
  ),
  quickPhrase(sourceKey: 'quick_phrases_v1', tableName: 'quick_phrase_rows'),
  searchService(
    sourceKey: 'search_services_v1',
    tableName: 'search_service_rows',
  ),
  ttsService(sourceKey: 'tts_services_v1', tableName: 'tts_service_rows'),
  instructionInjection(
    sourceKey: 'instruction_injections_v1',
    tableName: 'instruction_injection_rows',
  ),
  assistantTag(sourceKey: 'assistant_tags_v1', tableName: 'assistant_tag_rows'),
  memoryEntry(sourceKey: 'memory_entries_v1', tableName: 'memory_entry_rows'),
  userProfileField(
    sourceKey: 'user_profile_fields_v1',
    tableName: 'user_profile_field_rows',
  );

  const BusinessEntityKind({required this.sourceKey, required this.tableName});

  final String sourceKey;
  final String tableName;

  String get idColumn => this == provider ? 'provider_key' : 'id';
}

final class BusinessEntityValue {
  const BusinessEntityValue({
    required this.id,
    required this.sortOrder,
    required this.payload,
    this.assistantId,
  });

  final String id;
  final int sortOrder;
  final String payload;
  final String? assistantId;

  BusinessEntityValue copyWith({
    String? id,
    int? sortOrder,
    String? payload,
    String? assistantId,
  }) => BusinessEntityValue(
    id: id ?? this.id,
    sortOrder: sortOrder ?? this.sortOrder,
    payload: payload ?? this.payload,
    assistantId: assistantId ?? this.assistantId,
  );
}

final class BusinessSnapshot {
  BusinessSnapshot({
    required Map<BusinessEntityKind, List<BusinessEntityValue>> entities,
    required Map<String, Object> preferences,
    List<BusinessExtensionEntityValue> extensionEntities = const [],
  }) : entities = {
         for (final kind in BusinessEntityKind.values)
           kind: List<BusinessEntityValue>.unmodifiable(
             entities[kind] ?? const <BusinessEntityValue>[],
           ),
       },
       preferences = Map<String, Object>.unmodifiable(preferences),
       extensionEntities = List<BusinessExtensionEntityValue>.unmodifiable(
         extensionEntities,
       );

  final Map<BusinessEntityKind, List<BusinessEntityValue>> entities;
  final Map<String, Object> preferences;
  final List<BusinessExtensionEntityValue> extensionEntities;

  int entityCount(BusinessEntityKind kind) => entities[kind]!.length;
}
