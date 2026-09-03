import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';
import '../models/prompt_preset.dart';
import '../services/prompt_preset_store.dart';

class PromptPresetProvider with ChangeNotifier {
  PromptPresetProvider({required BusinessPreferences preferences})
    : _store = PromptPresetStore(preferences);

  final PromptPresetStore _store;
  List<PromptPreset> _presets = const <PromptPreset>[];
  Map<String, String> _activeByAssistant = const <String, String>{};
  bool _initialized = false;
  Future<void>? _initializationFuture;

  List<PromptPreset> get presets => List<PromptPreset>.unmodifiable(_presets);

  PromptPreset? getById(String id) {
    for (final preset in _presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  String? selectedPresetIdFor(String? assistantId) {
    final id = (assistantId ?? '').trim();
    if (id.isEmpty) return null;
    return _activeByAssistant[id];
  }

  PromptPreset? selectedPresetFor(String? assistantId) {
    final id = selectedPresetIdFor(assistantId);
    return id == null ? null : getById(id);
  }

  int enabledEntryCount(PromptPreset preset) =>
      preset.entries.where((entry) => entry.enabled).length;

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initializationFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await loadAll();
      _initialized = true;
    } finally {
      _initializationFuture = null;
    }
  }

  Future<void> loadAll() async {
    _presets = await _store.getAll();
    final active = await _store.getActiveByAssistant();
    final knownIds = _presets.map((preset) => preset.id).toSet();
    final cleanedActive = <String, String>{
      for (final entry in active.entries)
        if (knownIds.contains(entry.value)) entry.key: entry.value,
    };
    _activeByAssistant = cleanedActive;
    if (cleanedActive.length != active.length) {
      await _store.setActiveByAssistant(cleanedActive);
    }
    notifyListeners();
  }

  Future<void> addPreset(PromptPreset preset) async {
    await _store.add(preset);
    await loadAll();
  }

  Future<void> updatePreset(PromptPreset preset) async {
    await _store.update(preset);
    await loadAll();
  }

  Future<void> renamePreset(String id, String name) async {
    final preset = getById(id);
    if (preset == null) return;
    await updatePreset(preset.copyWith(name: name));
  }

  Future<void> deletePreset(String id) async {
    final nextPresets = _presets.where((preset) => preset.id != id).toList();
    if (nextPresets.length == _presets.length) return;
    final nextActive = <String, String>{
      for (final entry in _activeByAssistant.entries)
        if (entry.value != id) entry.key: entry.value,
    };
    await _store.save(nextPresets);
    await _store.setActiveByAssistant(nextActive);
    _presets = nextPresets;
    _activeByAssistant = nextActive;
    notifyListeners();
  }

  Future<void> clear() async {
    await _store.save(const <PromptPreset>[]);
    await _store.setActiveByAssistant(const <String, String>{});
    _presets = const <PromptPreset>[];
    _activeByAssistant = const <String, String>{};
    notifyListeners();
  }

  Future<void> reorderPresets({
    required int oldIndex,
    required int newIndex,
  }) async {
    if (oldIndex < 0 || oldIndex >= _presets.length) return;
    if (newIndex < 0 || newIndex >= _presets.length) return;
    final next = List<PromptPreset>.of(_presets);
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    _presets = next;
    notifyListeners();
    await _store.save(next);
  }

  Future<void> reorderEntries({
    required String presetId,
    required int oldIndex,
    required int newIndex,
  }) async {
    final preset = getById(presetId);
    if (preset == null) return;
    if (oldIndex < 0 || oldIndex >= preset.entries.length) return;
    if (newIndex < 0 || newIndex >= preset.entries.length) return;
    final entries = List<PromptPresetEntry>.of(preset.entries);
    final item = entries.removeAt(oldIndex);
    entries.insert(newIndex, item);
    final normalized = [
      for (var index = 0; index < entries.length; index++)
        entries[index].copyWith(sourceOrder: index),
    ];
    await updatePreset(preset.copyWith(entries: normalized));
  }

  Future<void> updateEntry({
    required String presetId,
    required PromptPresetEntry entry,
  }) async {
    final preset = getById(presetId);
    if (preset == null) return;
    final entries = [
      for (final item in preset.entries) item.id == entry.id ? entry : item,
    ];
    await updatePreset(preset.copyWith(entries: entries));
  }

  Future<void> setEntryEnabled({
    required String presetId,
    required String entryId,
    required bool enabled,
  }) async {
    final preset = getById(presetId);
    if (preset == null) return;
    final entry = preset.entries.where((item) => item.id == entryId);
    if (entry.isEmpty) return;
    await updateEntry(
      presetId: presetId,
      entry: entry.first.copyWith(enabled: enabled),
    );
  }

  Future<void> addEntry({
    required String presetId,
    required PromptPresetEntry entry,
  }) async {
    final preset = getById(presetId);
    if (preset == null) return;
    await updatePreset(preset.copyWith(entries: [...preset.entries, entry]));
  }

  Future<void> setSelectedPresetId(
    String? assistantId,
    String? presetId,
  ) async {
    final cleanAssistantId = (assistantId ?? '').trim();
    if (cleanAssistantId.isEmpty) return;
    final cleanPresetId = (presetId ?? '').trim();
    if (cleanPresetId.isNotEmpty && getById(cleanPresetId) == null) return;

    final next = Map<String, String>.from(_activeByAssistant);
    if (cleanPresetId.isEmpty) {
      next.remove(cleanAssistantId);
    } else {
      next[cleanAssistantId] = cleanPresetId;
    }
    _activeByAssistant = next;
    notifyListeners();
    await _store.setActiveByAssistant(next);
  }
}
