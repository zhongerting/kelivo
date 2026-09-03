import 'dart:convert';

enum PromptPresetSourceFormat { sillyTavern, kelivo }

extension PromptPresetSourceFormatJson on PromptPresetSourceFormat {
  static PromptPresetSourceFormat fromJson(Object? value) {
    return switch ((value ?? '').toString().trim().toLowerCase()) {
      'sillytavern' => PromptPresetSourceFormat.sillyTavern,
      _ => PromptPresetSourceFormat.kelivo,
    };
  }

  String toJson() => name;
}

enum PromptPresetRole { system, user, assistant }

extension PromptPresetRoleJson on PromptPresetRole {
  static PromptPresetRole fromJson(Object? value) {
    return switch ((value ?? '').toString().trim().toLowerCase()) {
      'user' => PromptPresetRole.user,
      'assistant' => PromptPresetRole.assistant,
      _ => PromptPresetRole.system,
    };
  }

  String toJson() => name;
}

enum PromptPresetAnchor { beforeChatHistory, afterChatHistory }

extension PromptPresetAnchorJson on PromptPresetAnchor {
  static PromptPresetAnchor fromJson(Object? value) {
    return switch ((value ?? '').toString().trim().toLowerCase()) {
      'afterchathistory' => PromptPresetAnchor.afterChatHistory,
      _ => PromptPresetAnchor.beforeChatHistory,
    };
  }

  String toJson() => name;
}

class PromptPresetEntry {
  const PromptPresetEntry({
    required this.id,
    required this.sourceIdentifier,
    required this.name,
    required this.content,
    required this.enabled,
    required this.role,
    required this.anchor,
    required this.sourceOrder,
  });

  final String id;
  final String sourceIdentifier;
  final String name;
  final String content;
  final bool enabled;
  final PromptPresetRole role;
  final PromptPresetAnchor anchor;
  final int sourceOrder;

  PromptPresetEntry copyWith({
    String? id,
    String? sourceIdentifier,
    String? name,
    String? content,
    bool? enabled,
    PromptPresetRole? role,
    PromptPresetAnchor? anchor,
    int? sourceOrder,
  }) {
    return PromptPresetEntry(
      id: id ?? this.id,
      sourceIdentifier: sourceIdentifier ?? this.sourceIdentifier,
      name: name ?? this.name,
      content: content ?? this.content,
      enabled: enabled ?? this.enabled,
      role: role ?? this.role,
      anchor: anchor ?? this.anchor,
      sourceOrder: sourceOrder ?? this.sourceOrder,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceIdentifier': sourceIdentifier,
    'name': name,
    'content': content,
    'enabled': enabled,
    'role': role.toJson(),
    'anchor': anchor.toJson(),
    'sourceOrder': sourceOrder,
  };

  static PromptPresetEntry fromJson(Map<String, dynamic> json) {
    return PromptPresetEntry(
      id: (json['id'] ?? '').toString(),
      sourceIdentifier: (json['sourceIdentifier'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      role: PromptPresetRoleJson.fromJson(json['role']),
      anchor: PromptPresetAnchorJson.fromJson(json['anchor']),
      sourceOrder: (json['sourceOrder'] as num?)?.toInt() ?? 0,
    );
  }
}

class PromptPreset {
  const PromptPreset({
    required this.id,
    required this.name,
    required this.sourceFormat,
    required this.entries,
  });

  final String id;
  final String name;
  final PromptPresetSourceFormat sourceFormat;
  final List<PromptPresetEntry> entries;

  PromptPreset copyWith({
    String? id,
    String? name,
    PromptPresetSourceFormat? sourceFormat,
    List<PromptPresetEntry>? entries,
  }) {
    return PromptPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      sourceFormat: sourceFormat ?? this.sourceFormat,
      entries: entries ?? this.entries,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'sourceFormat': sourceFormat.toJson(),
    'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
  };

  static PromptPreset fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    final entries = rawEntries is List
        ? rawEntries
              .whereType<Map>()
              .map(
                (entry) => PromptPresetEntry.fromJson(
                  entry.map((key, value) => MapEntry(key.toString(), value)),
                ),
              )
              .toList(growable: false)
        : const <PromptPresetEntry>[];
    return PromptPreset(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      sourceFormat: PromptPresetSourceFormatJson.fromJson(json['sourceFormat']),
      entries: entries,
    );
  }

  static String encodeList(List<PromptPreset> presets) => jsonEncode(
    presets.map((preset) => preset.toJson()).toList(growable: false),
  );

  static List<PromptPreset> decodeList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <PromptPreset>[];
      return [
        for (final item in decoded)
          if (item is Map)
            PromptPreset.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
      ];
    } catch (_) {
      return const <PromptPreset>[];
    }
  }
}
