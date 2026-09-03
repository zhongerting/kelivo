import 'package:uuid/uuid.dart';

import '../../../core/models/prompt_preset.dart';
import 'prompt_preset_macro_service.dart';

enum PromptPresetImportFormat { kelivo, sillyTavern }

class PromptPresetImportResult {
  const PromptPresetImportResult({
    required this.preset,
    required this.format,
    required this.importedEntries,
    required this.enabledEntries,
    required this.disabledEntries,
    required this.skippedMarkers,
    required this.skippedEntries,
    required this.skippedPluginEntries,
    required this.unorderedEntries,
    required this.duplicateIdentifiers,
    required this.missingIdentifiers,
    required this.unsupportedMacroNames,
    required this.adjustments,
  });

  final PromptPreset preset;
  final PromptPresetImportFormat format;
  final int importedEntries;
  final int enabledEntries;
  final int disabledEntries;
  final int skippedMarkers;
  final int skippedEntries;
  final int skippedPluginEntries;
  final int unorderedEntries;
  final int duplicateIdentifiers;
  final int missingIdentifiers;
  final List<String> unsupportedMacroNames;
  final List<String> adjustments;

  bool get hasWarnings =>
      skippedEntries > 0 ||
      unorderedEntries > 0 ||
      duplicateIdentifiers > 0 ||
      missingIdentifiers > 0 ||
      unsupportedMacroNames.isNotEmpty ||
      adjustments.isNotEmpty;
}

class PromptPresetImportService {
  PromptPresetImportService._();

  static const _blockedPluginIdentifiers = <String>{
    'spresetsettings',
    'regexes-bindings',
    'regexbindings',
    'tavern_helper',
    'tavern-helper',
    'regex_scripts',
  };

  static PromptPresetImportResult? parse(
    Object? decoded, {
    required String fallbackName,
  }) {
    if (decoded is! Map) return null;
    final root = _stringKeyedMap(decoded);
    final rawPrompts = root['prompts'];
    final rawPromptOrder = root['prompt_order'];
    if (rawPrompts is! List || rawPromptOrder is! List) return null;

    final orderDefinitions = <Map<String, Object?>>[];
    for (final raw in rawPromptOrder) {
      if (raw is! Map) continue;
      final definition = _stringKeyedMap(raw);
      if (definition['order'] is List) orderDefinitions.add(definition);
    }
    if (orderDefinitions.isEmpty) return null;

    final selectedDefinition = orderDefinitions.firstWhere(
      (definition) => definition['character_id'].toString() == '100001',
      orElse: () => orderDefinitions.first,
    );
    final order = selectedDefinition['order']! as List;

    final prompts = <String, List<Map<String, Object?>>>{};
    var duplicateIdentifiers = 0;
    for (final raw in rawPrompts) {
      if (raw is! Map) continue;
      final prompt = _stringKeyedMap(raw);
      final identifier = (prompt['identifier'] ?? '').toString().trim();
      if (identifier.isEmpty) continue;
      final list = prompts.putIfAbsent(
        identifier,
        () => <Map<String, Object?>>[],
      );
      if (list.isNotEmpty) duplicateIdentifiers++;
      list.add(prompt);
    }

    final usedIdentifiers = <String>{};
    final imported = <PromptPresetEntry>[];
    final adjustments = <String>[];
    final unsupportedMacros = <String>{};
    var skippedMarkers = 0;
    var skippedEntries = 0;
    var skippedPluginEntries = 0;
    var unorderedEntries = 0;
    var missingIdentifiers = 0;
    var emptyEntries = 0;
    var seenOrderIdentifiers = <String>{};
    var afterChatHistory = false;

    for (var sourceOrder = 0; sourceOrder < order.length; sourceOrder++) {
      final rawOrderEntry = order[sourceOrder];
      if (rawOrderEntry is! Map) {
        skippedEntries++;
        adjustments.add('Skipped malformed prompt_order entry.');
        continue;
      }
      final orderEntry = _stringKeyedMap(rawOrderEntry);
      final identifier = (orderEntry['identifier'] ?? '').toString().trim();
      if (identifier.isEmpty) {
        skippedEntries++;
        adjustments.add('Skipped prompt_order entry without an identifier.');
        continue;
      }
      usedIdentifiers.add(identifier);

      final promptList = prompts[identifier];
      final isOrderMarker = orderEntry['marker'] == true;
      final isChatHistoryIdentifier = identifier.toLowerCase() == 'chathistory';
      final isPromptMarker =
          promptList?.isNotEmpty == true && promptList!.first['marker'] == true;
      if (isChatHistoryIdentifier) {
        skippedMarkers++;
        afterChatHistory = true;
        continue;
      }
      if (isOrderMarker || isPromptMarker) {
        skippedMarkers++;
        continue;
      }

      if (!seenOrderIdentifiers.add(identifier)) {
        duplicateIdentifiers++;
        skippedEntries++;
        continue;
      }
      if (promptList == null || promptList.isEmpty) {
        missingIdentifiers++;
        skippedEntries++;
        continue;
      }
      if (promptList.length > 1) {
        duplicateIdentifiers++;
        skippedEntries++;
        continue;
      }

      final prompt = promptList.single;
      if (_isPluginConfiguration(prompt, identifier)) {
        skippedPluginEntries++;
        skippedEntries++;
        continue;
      }

      final rawContent = prompt['content'];
      if (rawContent is! String || rawContent.trim().isEmpty) {
        emptyEntries++;
        skippedEntries++;
        continue;
      }

      final rawRole = prompt['role'];
      final role = PromptPresetRoleJson.fromJson(rawRole);
      if (!_isKnownRole(rawRole)) {
        adjustments.add(
          'Entry "$identifier" had an unsupported role; using system.',
        );
      }

      final injectionPosition = _integerValue(prompt['injection_position']);
      var enabled = orderEntry['enabled'] is bool
          ? orderEntry['enabled'] as bool
          : prompt['enabled'] is bool
          ? prompt['enabled'] as bool
          : true;
      if (injectionPosition != null && injectionPosition != 0) {
        if (enabled) {
          adjustments.add(
            'Entry "$identifier" uses unsupported depth injection; disabled.',
          );
        } else {
          adjustments.add(
            'Entry "$identifier" uses unsupported depth injection; kept disabled.',
          );
        }
        enabled = false;
      }

      final macroNames = PromptPresetMacroService.findUnsupportedMacroNames(
        rawContent,
      );
      unsupportedMacros.addAll(macroNames);
      imported.add(
        PromptPresetEntry(
          id: const Uuid().v4(),
          sourceIdentifier: identifier,
          name: (prompt['name'] ?? identifier).toString(),
          content: rawContent,
          enabled: enabled,
          role: role,
          anchor: afterChatHistory
              ? PromptPresetAnchor.afterChatHistory
              : PromptPresetAnchor.beforeChatHistory,
          sourceOrder: sourceOrder,
        ),
      );
    }

    for (final raw in rawPrompts) {
      if (raw is! Map) continue;
      final prompt = _stringKeyedMap(raw);
      final identifier = (prompt['identifier'] ?? '').toString().trim();
      if (identifier.isEmpty || usedIdentifiers.contains(identifier)) continue;
      unorderedEntries++;
      skippedEntries++;
      if (_isPluginConfiguration(prompt, identifier)) {
        skippedPluginEntries++;
      }
    }

    final name = fallbackName.trim().isEmpty ? 'Prompt preset' : fallbackName;
    final preset = PromptPreset(
      id: const Uuid().v4(),
      name: name.trim(),
      sourceFormat: PromptPresetSourceFormat.sillyTavern,
      entries: imported,
    );
    final enabledCount = imported.where((entry) => entry.enabled).length;
    return PromptPresetImportResult(
      preset: preset,
      format: PromptPresetImportFormat.sillyTavern,
      importedEntries: imported.length,
      enabledEntries: enabledCount,
      disabledEntries: imported.length - enabledCount,
      skippedMarkers: skippedMarkers,
      skippedEntries: skippedEntries,
      skippedPluginEntries: skippedPluginEntries,
      unorderedEntries: unorderedEntries,
      duplicateIdentifiers: duplicateIdentifiers,
      missingIdentifiers: missingIdentifiers,
      unsupportedMacroNames: unsupportedMacros.toList(growable: false),
      adjustments: [
        ...adjustments,
        if (emptyEntries > 0)
          'Skipped $emptyEntries entries with empty content.',
        if (unorderedEntries > 0)
          'Skipped $unorderedEntries prompts not present in prompt_order.',
      ],
    );
  }

  static Map<String, Object?> _stringKeyedMap(Map raw) => {
    for (final entry in raw.entries) entry.key.toString(): entry.value,
  };

  static bool _isPluginConfiguration(
    Map<String, Object?> prompt,
    String identifier,
  ) {
    final id = identifier.trim().toLowerCase();
    final name = (prompt['name'] ?? '').toString().trim().toLowerCase();
    return _blockedPluginIdentifiers.contains(id) ||
        _blockedPluginIdentifiers.contains(name);
  }

  static bool _isKnownRole(Object? value) {
    if (value is! String) return false;
    return switch (value.trim().toLowerCase()) {
      'system' || 'user' || 'assistant' => true,
      _ => false,
    };
  }

  static int? _integerValue(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse((value ?? '').toString().trim());
  }
}
