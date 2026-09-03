import 'dart:convert';

import '../database/business_preferences.dart';
import '../models/prompt_preset.dart';

class PromptPresetStore {
  PromptPresetStore(this._preferences);

  static const String presetsKey = 'prompt_presets_v1';
  static const String activeByAssistantKey =
      'prompt_preset_active_by_assistant_v1';

  final BusinessPreferences _preferences;

  Future<List<PromptPreset>> getAll() async {
    await _preferences.load();
    final raw = _preferences.getString(presetsKey);
    if (raw == null || raw.isEmpty) return <PromptPreset>[];
    return List<PromptPreset>.of(PromptPreset.decodeList(raw));
  }

  Future<void> save(List<PromptPreset> presets) async {
    await _preferences.setString(presetsKey, PromptPreset.encodeList(presets));
  }

  Future<void> add(PromptPreset preset) async {
    final presets = await getAll();
    presets.add(preset);
    await save(presets);
  }

  Future<void> update(PromptPreset preset) async {
    final presets = await getAll();
    final index = presets.indexWhere((item) => item.id == preset.id);
    if (index == -1) return;
    presets[index] = preset;
    await save(presets);
  }

  Future<Map<String, String>> getActiveByAssistant() async {
    await _preferences.load();
    final raw = _preferences.getString(activeByAssistantKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final result = <String, String>{};
      for (final entry in decoded.entries) {
        final assistantId = entry.key.toString().trim();
        final presetId = entry.value.toString().trim();
        if (assistantId.isEmpty || presetId.isEmpty) continue;
        result[assistantId] = presetId;
      }
      return result;
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> setActiveByAssistant(Map<String, String> values) async {
    final cleaned = <String, String>{};
    values.forEach((assistantId, presetId) {
      final cleanAssistantId = assistantId.trim();
      final cleanPresetId = presetId.trim();
      if (cleanAssistantId.isNotEmpty && cleanPresetId.isNotEmpty) {
        cleaned[cleanAssistantId] = cleanPresetId;
      }
    });
    await _preferences.setString(activeByAssistantKey, jsonEncode(cleaned));
  }
}
