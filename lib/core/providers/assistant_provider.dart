import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../utils/sandbox_path_resolver.dart';
import '../database/business_preferences.dart';
import '../models/assistant.dart';
import '../models/assistant_regex.dart';
import '../models/preset_message.dart';
import 'prompt_preset_provider.dart';
import 'world_book_provider.dart';
import '../services/chat/chat_service.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/avatar_cache.dart';
import '../../utils/app_directories.dart';

class AssistantProvider extends ChangeNotifier {
  static const String _assistantsKey = 'assistants_v1';
  static const String _currentAssistantKey = 'current_assistant_id_v1';

  final BusinessPreferences preferences;
  final List<Assistant> _assistants = <Assistant>[];
  String? _currentAssistantId;
  final ChatService? chatService;
  final PromptPresetProvider? promptPresetProvider;
  final WorldBookProvider? worldBookProvider;

  List<Assistant> get assistants => List.unmodifiable(_assistants);
  String? get currentAssistantId => _currentAssistantId;
  Assistant? get currentAssistant {
    final idx = _assistants.indexWhere((a) => a.id == _currentAssistantId);
    if (idx != -1) return _assistants[idx];
    if (_assistants.isNotEmpty) return _assistants.first;
    return null;
  }

  bool get currentSearchEnabled => currentAssistant?.searchEnabled ?? false;

  AssistantProvider({
    required this.preferences,
    this.chatService,
    this.promptPresetProvider,
    this.worldBookProvider,
  }) {
    loaded = _load();
  }

  late final Future<void> loaded;

  Future<void> _load() async {
    if (!preferences.isLoaded) {
      await preferences.load();
    }
    final raw = preferences.getString(_assistantsKey);
    if (raw != null && raw.isNotEmpty) {
      _assistants
        ..clear()
        ..addAll(_decodeAssistants(raw));
      // Fix any sandboxed local paths (avatars/backgrounds) imported from other platforms
      bool changed = false;
      for (int i = 0; i < _assistants.length; i++) {
        final a = _assistants[i];
        String? av = a.avatar;
        String? bg = a.background;
        var itemChanged = false;
        if (av != null &&
            av.isNotEmpty &&
            (av.startsWith('/') || av.contains(':')) &&
            !av.startsWith('http')) {
          final fixed = SandboxPathResolver.fix(av);
          if (fixed != av) {
            av = fixed;
            changed = true;
            itemChanged = true;
          }
        }
        if (bg != null &&
            bg.isNotEmpty &&
            (bg.startsWith('/') || bg.contains(':')) &&
            !bg.startsWith('http')) {
          final fixedBg = SandboxPathResolver.fix(bg);
          if (fixedBg != bg) {
            bg = fixedBg;
            changed = true;
            itemChanged = true;
          }
        }
        if (itemChanged) {
          _assistants[i] = a.copyWith(avatar: av, background: bg);
        }
      }
      if (changed) {
        try {
          await _persist();
        } catch (_) {}
      }
    }
    // Do not create defaults here because localization is not available.
    // Defaults will be ensured later via ensureDefaults(context).
    // Restore current assistant if present
    final savedValue = preferences.get(_currentAssistantKey);
    final savedId = savedValue is String ? savedValue : null;
    if (savedId != null && _assistants.any((a) => a.id == savedId)) {
      _currentAssistantId = savedId;
    } else {
      _currentAssistantId = null;
    }
    notifyListeners();
  }

  List<Assistant> _decodeAssistants(String raw) {
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in decoded)
          if (e is Map) Assistant.fromJson(e.cast<String, dynamic>()),
      ];
    } catch (_) {
      return const <Assistant>[];
    }
  }

  Assistant _defaultAssistant(AppLocalizations l10n) => Assistant(
    id: const Uuid().v4(),
    name: l10n.assistantProviderDefaultAssistantName,
    systemPrompt: '',
    thinkingBudget: null,
    temperature: null,
    topP: null,
    limitContextMessages: false,
  );

  // Ensure localized default assistants exist; call this after localization is ready.
  Future<void> ensureDefaults(dynamic context) async {
    await loaded;
    if (_assistants.isNotEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    // 1) 默认助手
    _assistants.add(_defaultAssistant(l10n));
    // 2) 示例助手（带提示词模板）
    _assistants.add(
      Assistant(
        id: const Uuid().v4(),
        name: l10n.assistantProviderSampleAssistantName,
        systemPrompt: l10n.assistantProviderSampleAssistantSystemPrompt(
          '{model_name}',
        ),
        temperature: null,
        topP: null,
        limitContextMessages: false,
      ),
    );
    await _persist();
    // Set current assistant if not set
    if (_currentAssistantId == null && _assistants.isNotEmpty) {
      _currentAssistantId = _assistants.first.id;
      await preferences.setString(_currentAssistantKey, _currentAssistantId!);
    }
    notifyListeners();
  }

  String _buildCopyName(Assistant source, AppLocalizations? l10n) {
    final suffix = (l10n?.assistantSettingsCopySuffix ?? 'Copy').trim();
    final baseName = source.name.trim().isEmpty
        ? (l10n?.assistantProviderNewAssistantName ?? 'Assistant')
        : source.name.trim();
    final existingNames = _assistants.map((a) => a.name).toSet();

    String candidate = suffix.isEmpty ? baseName : '$baseName $suffix';
    int counter = 2;
    while (existingNames.contains(candidate)) {
      final counterSuffix = suffix.isEmpty ? '$counter' : '$suffix $counter';
      candidate = '$baseName $counterSuffix';
      counter++;
    }
    return candidate;
  }

  Future<String?> _duplicateLocalFile(
    String? rawPath, {
    required bool isAvatar,
    required String newId,
  }) async {
    final raw = (rawPath ?? '').trim();
    if (raw.isEmpty) return rawPath;
    if (raw.startsWith('http') || raw.startsWith('data:')) return rawPath;
    final fixed = SandboxPathResolver.fix(raw);
    final src = File(fixed);
    if (!await src.exists()) return rawPath;

    try {
      final dir = isAvatar
          ? await AppDirectories.getAvatarsDirectory()
          : await AppDirectories.getImagesDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      String ext = '';
      final dot = fixed.lastIndexOf('.');
      if (dot != -1 && dot < fixed.length - 1) {
        ext = fixed.substring(dot + 1).toLowerCase();
        if (ext.length > 6) ext = 'jpg';
      } else {
        ext = 'jpg';
      }
      final prefix = isAvatar ? 'assistant' : 'background';
      final dest = File(
        '${dir.path}/${prefix}_${newId}_${DateTime.now().millisecondsSinceEpoch}.$ext',
      );
      await src.copy(dest.path);
      return dest.path;
    } catch (_) {
      return rawPath;
    }
  }

  Future<String?> _copyLocalAssetToManagedDirectory(
    String? rawPath, {
    required Future<Directory> Function() directoryAsync,
    required String filenamePrefix,
    required String id,
  }) async {
    final raw = (rawPath ?? '').trim();
    if (raw.isEmpty || raw.startsWith('http') || raw.startsWith('data:')) {
      return rawPath;
    }
    if (!(raw.startsWith('/') || raw.contains(':'))) return rawPath;

    final fixed = SandboxPathResolver.fix(raw);
    final src = File(fixed);
    if (!await src.exists()) return rawPath;

    final managedDir = await directoryAsync();
    final managedRoot = p.normalize(managedDir.absolute.path);
    final sourcePath = p.normalize(src.absolute.path);
    if (p.isWithin(managedRoot, sourcePath)) return fixed;

    if (!await managedDir.exists()) {
      await managedDir.create(recursive: true);
    }

    var ext = p.extension(fixed).toLowerCase();
    if (ext.isEmpty || ext.length > 7) ext = '.jpg';
    final safeId = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final dest = File(
      p.join(
        managedDir.path,
        '${filenamePrefix}_${safeId}_${DateTime.now().millisecondsSinceEpoch}$ext',
      ),
    );
    await src.copy(dest.path);
    return dest.path;
  }

  Future<void> _deleteManagedFileIfOwned(
    String? rawPath, {
    required Future<Directory> Function() directoryAsync,
    required String? replacementPath,
  }) async {
    final raw = (rawPath ?? '').trim();
    if (raw.isEmpty) return;
    try {
      final dir = await directoryAsync();
      final root = p.normalize(dir.absolute.path);
      final targetFile = File(raw);
      final target = p.normalize(targetFile.absolute.path);
      if (!p.isWithin(root, target)) return;
      if (replacementPath != null &&
          p.equals(target, p.normalize(File(replacementPath).absolute.path))) {
        return;
      }
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    await preferences.setString(
      _assistantsKey,
      Assistant.encodeList(_assistants),
    );
  }

  Future<void> _restoreStoredPreference(
    String key, {
    required bool existed,
    required Object? value,
  }) async {
    if (!existed) {
      await preferences.remove(key);
      return;
    }
    if (value is! String) {
      throw StateError('assistant_restore_invalid_preference:$key');
    }
    await preferences.setString(key, value);
  }

  Future<List<String>> _restoreAssistantSnapshot({
    required List<Assistant> assistants,
    required String? currentAssistantId,
    required bool persistedAssistants,
    required Object? persistedAssistantsValue,
    required bool persistedCurrentAssistant,
    required Object? persistedCurrentAssistantValue,
  }) async {
    _assistants
      ..clear()
      ..addAll(assistants);
    _currentAssistantId = currentAssistantId;

    final errors = <String>[];
    try {
      await _restoreStoredPreference(
        _assistantsKey,
        existed: persistedAssistants,
        value: persistedAssistantsValue,
      );
    } catch (error) {
      errors.add('assistants: $error');
    }
    try {
      await _restoreStoredPreference(
        _currentAssistantKey,
        existed: persistedCurrentAssistant,
        value: persistedCurrentAssistantValue,
      );
    } catch (error) {
      errors.add('current_assistant: $error');
    }
    return errors;
  }

  Future<void> setCurrentAssistant(String id) async {
    await loaded;
    if (_currentAssistantId == id) return;
    await preferences.setString(_currentAssistantKey, id);
    _currentAssistantId = id;
    notifyListeners();
  }

  /// Restores a previously selected assistant during a failed cross-provider
  /// import. A null value removes the persisted selection as well.
  Future<void> restoreCurrentAssistantId(String? id) async {
    await loaded;
    final previousId = _currentAssistantId;
    final persisted = preferences.containsKey(_currentAssistantKey);
    final persistedValue = preferences.get(_currentAssistantKey);
    try {
      await _restoreStoredPreference(
        _currentAssistantKey,
        existed: id != null,
        value: id,
      );
      _currentAssistantId = id;
      if (previousId != id) notifyListeners();
    } catch (error, stackTrace) {
      _currentAssistantId = previousId;
      final rollbackErrors = <String>[];
      try {
        await _restoreStoredPreference(
          _currentAssistantKey,
          existed: persisted,
          value: persistedValue,
        );
      } catch (rollbackError) {
        rollbackErrors.add('current_assistant: $rollbackError');
      }
      if (rollbackErrors.isEmpty) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      Error.throwWithStackTrace(
        StateError(
          'Assistant current ID restore failed: $error; '
          'rollback failed: ${rollbackErrors.join('; ')}',
        ),
        stackTrace,
      );
    }
  }

  Assistant? getById(String id) {
    final idx = _assistants.indexWhere((a) => a.id == id);
    if (idx == -1) return null;
    return _assistants[idx];
  }

  // Lightweight accessor so callers don't depend on Assistant.presetMessages symbol
  List<Map<String, String>> getPresetMessagesForAssistant(String? assistantId) {
    Assistant? a;
    if (assistantId != null) {
      a = getById(assistantId);
    } else {
      a = currentAssistant;
    }
    if (a == null) return const <Map<String, String>>[];
    return [
      for (final m in a.presetMessages) {'role': m.role, 'content': m.content},
    ];
  }

  Future<String> addAssistant({String? name, dynamic context}) async {
    await loaded;
    final a = Assistant(
      id: const Uuid().v4(),
      name:
          (name ??
          (context != null
              ? AppLocalizations.of(context)!.assistantProviderNewAssistantName
              : 'New Assistant')),
      temperature: null,
      topP: null,
      limitContextMessages: false,
    );
    _assistants.add(a);
    await _persist();
    notifyListeners();
    return a.id;
  }

  /// Add a fully materialized assistant produced by an import flow.
  ///
  /// Importers use this after all parsing and asset preparation has succeeded,
  /// so a partially parsed character card can never enter the normal list.
  Future<void> addAssistantObject(
    Assistant assistant, {
    bool select = false,
  }) async {
    await loaded;
    if (_assistants.any((item) => item.id == assistant.id)) {
      throw StateError('assistant_id_already_exists');
    }
    final previousAssistants = List<Assistant>.of(_assistants);
    final previousCurrentAssistantId = _currentAssistantId;
    final persistedAssistants = preferences.containsKey(_assistantsKey);
    final persistedAssistantsValue = preferences.get(_assistantsKey);
    final persistedCurrentAssistant = preferences.containsKey(
      _currentAssistantKey,
    );
    final persistedCurrentAssistantValue = preferences.get(
      _currentAssistantKey,
    );

    try {
      _assistants.add(assistant);
      await _persist();
      if (select) {
        await preferences.setString(_currentAssistantKey, assistant.id);
        _currentAssistantId = assistant.id;
      }
      notifyListeners();
    } catch (error, stackTrace) {
      final rollbackErrors = await _restoreAssistantSnapshot(
        assistants: previousAssistants,
        currentAssistantId: previousCurrentAssistantId,
        persistedAssistants: persistedAssistants,
        persistedAssistantsValue: persistedAssistantsValue,
        persistedCurrentAssistant: persistedCurrentAssistant,
        persistedCurrentAssistantValue: persistedCurrentAssistantValue,
      );
      if (rollbackErrors.isEmpty) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      Error.throwWithStackTrace(
        StateError(
          'Assistant add failed: $error; '
          'rollback failed: ${rollbackErrors.join('; ')}',
        ),
        stackTrace,
      );
    }
  }

  /// Roll back an assistant created by an import before it becomes user data.
  Future<bool> removeAssistantObject(String id) async {
    await loaded;
    final index = _assistants.indexWhere((item) => item.id == id);
    if (index < 0) return false;
    final previousAssistants = List<Assistant>.of(_assistants);
    final previousCurrentAssistantId = _currentAssistantId;
    final persistedAssistants = preferences.containsKey(_assistantsKey);
    final persistedAssistantsValue = preferences.get(_assistantsKey);
    final persistedCurrentAssistant = preferences.containsKey(
      _currentAssistantKey,
    );
    final persistedCurrentAssistantValue = preferences.get(
      _currentAssistantKey,
    );

    try {
      _assistants.removeAt(index);
      if (_currentAssistantId == id) {
        _currentAssistantId = _assistants.isEmpty ? null : _assistants.first.id;
      }
      await _persist();
      if (_currentAssistantId != previousCurrentAssistantId) {
        await restoreCurrentAssistantId(_currentAssistantId);
      }
      notifyListeners();
      return true;
    } catch (error, stackTrace) {
      final rollbackErrors = await _restoreAssistantSnapshot(
        assistants: previousAssistants,
        currentAssistantId: previousCurrentAssistantId,
        persistedAssistants: persistedAssistants,
        persistedAssistantsValue: persistedAssistantsValue,
        persistedCurrentAssistant: persistedCurrentAssistant,
        persistedCurrentAssistantValue: persistedCurrentAssistantValue,
      );
      if (rollbackErrors.isEmpty) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      Error.throwWithStackTrace(
        StateError(
          'Assistant remove failed: $error; '
          'rollback failed: ${rollbackErrors.join('; ')}',
        ),
        stackTrace,
      );
    }
  }

  Future<String?> duplicateAssistant(
    String id, {
    AppLocalizations? l10n,
  }) async {
    final idx = _assistants.indexWhere((a) => a.id == id);
    if (idx == -1) return null;
    final source = _assistants[idx];
    final newId = const Uuid().v4();
    final activeWorldBookIds = worldBookProvider?.activeBookIdsFor(id);
    final selectedPromptPresetId = promptPresetProvider?.selectedPresetIdFor(
      id,
    );

    final avatarCopy = await _duplicateLocalFile(
      source.avatar,
      isAvatar: true,
      newId: newId,
    );
    final backgroundCopy = await _duplicateLocalFile(
      source.background,
      isAvatar: false,
      newId: newId,
    );

    final copy = source.copyWith(
      id: newId,
      name: _buildCopyName(source, l10n),
      avatar: avatarCopy,
      background: backgroundCopy,
      mcpServerIds: List<String>.of(source.mcpServerIds),
      localToolIds: List<String>.of(source.localToolIds),
      healthDataTypeIds: List<String>.of(source.healthDataTypeIds),
      customHeaders: source.customHeaders
          .map((e) => Map<String, String>.from(e))
          .toList(),
      customBody: source.customBody
          .map((e) => Map<String, String>.from(e))
          .toList(),
      presetMessages: source.presetMessages
          .map((m) => PresetMessage(role: m.role, content: m.content))
          .toList(),
      regexRules: source.regexRules
          .map(
            (r) => AssistantRegex(
              id: const Uuid().v4(),
              name: r.name,
              pattern: r.pattern,
              replacement: r.replacement,
              scopes: List<AssistantRegexScope>.of(r.scopes),
              visualOnly: r.visualOnly,
              replaceOnly: r.replaceOnly,
              enabled: r.enabled,
            ),
          )
          .toList(),
    );

    _assistants.insert(idx + 1, copy);
    await _persist();
    if (activeWorldBookIds != null && activeWorldBookIds.isNotEmpty) {
      try {
        await worldBookProvider!.setActiveBookIds(
          activeWorldBookIds,
          assistantId: newId,
        );
      } catch (_) {}
    }
    if (selectedPromptPresetId != null) {
      try {
        await promptPresetProvider!.setSelectedPresetId(
          newId,
          selectedPromptPresetId,
        );
      } catch (_) {}
    }
    notifyListeners();
    return copy.id;
  }

  Future<void> updateAssistant(Assistant updated) async {
    final idx = _assistants.indexWhere((a) => a.id == updated.id);
    if (idx == -1) return;

    var next = updated;

    try {
      final prev = _assistants[idx];
      final raw = (updated.avatar ?? '').trim();
      final prevRaw = (prev.avatar ?? '').trim();
      final changed = raw != prevRaw;

      if (changed) {
        final avatarPath = await _copyLocalAssetToManagedDirectory(
          raw,
          directoryAsync: AppDirectories.getAvatarsDirectory,
          filenamePrefix: 'assistant',
          id: updated.id,
        );
        if (avatarPath != updated.avatar) {
          await _deleteManagedFileIfOwned(
            prevRaw,
            directoryAsync: AppDirectories.getAvatarsDirectory,
            replacementPath: avatarPath,
          );
          next = updated.copyWith(avatar: avatarPath);
        } else if (raw.isEmpty) {
          await _deleteManagedFileIfOwned(
            prevRaw,
            directoryAsync: AppDirectories.getAvatarsDirectory,
            replacementPath: null,
          );
        }
      }

      // Prefetch URL avatar to allow offline display later
      if (changed && raw.startsWith('http')) {
        try {
          await AvatarCache.getPath(raw);
        } catch (_) {}
      }

      // Handle background persistence similar to avatar, but under images/
      final bgRaw = (updated.background ?? '').trim();
      final prevBgRaw = (prev.background ?? '').trim();
      final bgChanged = bgRaw != prevBgRaw;
      if (bgChanged) {
        final backgroundPath = await _copyLocalAssetToManagedDirectory(
          bgRaw,
          directoryAsync: AppDirectories.getImagesDirectory,
          filenamePrefix: 'background',
          id: updated.id,
        );
        if (backgroundPath != updated.background) {
          await _deleteManagedFileIfOwned(
            prevBgRaw,
            directoryAsync: AppDirectories.getImagesDirectory,
            replacementPath: backgroundPath,
          );
          next = next.copyWith(background: backgroundPath);
        } else if (bgRaw.isEmpty) {
          await _deleteManagedFileIfOwned(
            prevBgRaw,
            directoryAsync: AppDirectories.getImagesDirectory,
            replacementPath: null,
          );
        }
      }
    } catch (_) {
      // On any failure, fall back to the provided value unchanged.
    }

    _assistants[idx] = next;
    await _persist();
    notifyListeners();
  }

  Future<void> setSearchEnabledForCurrentAssistant(bool enabled) async {
    final a = currentAssistant;
    if (a == null || a.searchEnabled == enabled) return;
    await updateAssistant(a.copyWith(searchEnabled: enabled));
  }

  Future<void> reorderAssistantRegex({
    required String assistantId,
    required int oldIndex,
    required int newIndex,
  }) async {
    final idx = _assistants.indexWhere((a) => a.id == assistantId);
    if (idx == -1) return;
    final list = List<AssistantRegex>.of(_assistants[idx].regexRules);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex < 0 || newIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    _assistants[idx] = _assistants[idx].copyWith(regexRules: list);
    notifyListeners();
    await _persist();
  }

  Future<bool> deleteAssistant(String id) async {
    final idx = _assistants.indexWhere((a) => a.id == id);
    if (idx == -1) return false;
    // Do not allow deleting the last remaining assistant
    if (_assistants.length <= 1) return false;

    await chatService?.deleteConversationsForAssistant(id);
    try {
      await worldBookProvider?.setActiveBookIds(
        const <String>[],
        assistantId: id,
      );
    } catch (_) {}
    try {
      await promptPresetProvider?.setSelectedPresetId(id, null);
    } catch (_) {}

    final removingCurrent = _assistants[idx].id == _currentAssistantId;
    _assistants.removeAt(idx);
    if (removingCurrent) {
      _currentAssistantId = _assistants.isNotEmpty
          ? _assistants.first.id
          : null;
    }
    await _persist();
    if (_currentAssistantId != null) {
      await preferences.setString(_currentAssistantKey, _currentAssistantId!);
    } else {
      await preferences.remove(_currentAssistantKey);
    }
    notifyListeners();
    return true;
  }

  Future<void> reorderAssistants(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= _assistants.length) return;
    if (newIndex < 0 || newIndex >= _assistants.length) return;

    final assistant = _assistants.removeAt(oldIndex);
    _assistants.insert(newIndex, assistant);

    // Notify listeners immediately for smooth UI update
    notifyListeners();

    // Then persist the changes
    await _persist();
  }

  // Reorder only within a subset (e.g., assistants belonging to a tag group or ungrouped).
  // subsetIds defines the set and order boundary; other assistants remain in place.
  Future<void> reorderAssistantsWithin({
    required List<String> subsetIds,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (oldIndex == newIndex) return;
    if (subsetIds.isEmpty) return;

    // Build subset indices in the master list preserving current order
    final idSet = subsetIds.toSet();
    final subsetIndices = <int>[];
    for (int i = 0; i < _assistants.length; i++) {
      if (idSet.contains(_assistants[i].id)) subsetIndices.add(i);
    }
    if (subsetIndices.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= subsetIndices.length) return;
    if (newIndex < 0 || newIndex >= subsetIndices.length) return;

    // Extract subset in current order
    final subset = subsetIndices
        .map((i) => _assistants[i])
        .toList(growable: true);
    final moved = subset.removeAt(oldIndex);
    subset.insert(newIndex, moved);

    // Merge back into master list
    final merged = <Assistant>[];
    int take = 0;
    for (int i = 0; i < _assistants.length; i++) {
      final a = _assistants[i];
      if (idSet.contains(a.id)) {
        merged.add(subset[take++]);
      } else {
        merged.add(a);
      }
    }
    _assistants
      ..clear()
      ..addAll(merged);

    notifyListeners();
    await _persist();
  }
}
