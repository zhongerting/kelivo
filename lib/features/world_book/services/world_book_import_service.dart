import '../../../core/models/world_book.dart';

enum WorldBookImportFormat { kelivo, sillyTavern }

class WorldBookImportResult {
  const WorldBookImportResult({
    required this.book,
    required this.format,
    this.skippedEntries = 0,
    this.hasUnsupportedSettings = false,
  });

  final WorldBook book;
  final WorldBookImportFormat format;
  final int skippedEntries;
  final bool hasUnsupportedSettings;
}

class WorldBookImportService {
  const WorldBookImportService._();

  static WorldBookImportResult? parse(
    dynamic decoded, {
    String fallbackName = '',
  }) {
    if (decoded is! Map) return null;

    try {
      final root = decoded.cast<String, dynamic>();
      final source = _findBookSource(root);
      if (source == null) return null;

      if (_isSillyTavernBook(source)) {
        return _parseSillyTavern(source, fallbackName: fallbackName);
      }

      final rawEntries = source['entries'];
      if (rawEntries is! List) return null;
      return WorldBookImportResult(
        book: _withFallbackName(WorldBook.fromJson(source), fallbackName),
        format: WorldBookImportFormat.kelivo,
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _findBookSource(Map<String, dynamic> root) {
    final data = _asMap(root['data']);
    final dataCharacterBook = _asMap(data?['character_book']);
    if (dataCharacterBook != null && dataCharacterBook.containsKey('entries')) {
      return dataCharacterBook;
    }

    final characterBook = _asMap(root['character_book']);
    if (characterBook != null && characterBook.containsKey('entries')) {
      return characterBook;
    }

    if (data != null && data.containsKey('entries')) return data;
    if (root.containsKey('entries')) return root;
    return null;
  }

  static bool _isSillyTavernBook(Map<String, dynamic> source) {
    final entries = source['entries'];
    if (entries is Map) return true;
    if (entries is! List) return false;

    if (source.containsKey('scan_depth') ||
        source.containsKey('token_budget') ||
        source.containsKey('recursive_scanning')) {
      return true;
    }

    for (final value in entries) {
      final entry = _asMap(value);
      if (entry == null) continue;
      if (entry.containsKey('key') ||
          entry.containsKey('keys') ||
          entry.containsKey('keysecondary') ||
          entry.containsKey('secondary_keys') ||
          entry.containsKey('uid') ||
          entry.containsKey('insertion_order') ||
          entry.containsKey('constant') ||
          entry.containsKey('disable')) {
        return true;
      }
    }
    return false;
  }

  static WorldBookImportResult _parseSillyTavern(
    Map<String, dynamic> source, {
    required String fallbackName,
  }) {
    final rawEntries = source['entries'];
    final indexedEntries = <({dynamic key, dynamic value})>[];
    if (rawEntries is Map) {
      for (final item in rawEntries.entries) {
        indexedEntries.add((key: item.key, value: item.value));
      }
    } else if (rawEntries is List) {
      for (var index = 0; index < rawEntries.length; index++) {
        indexedEntries.add((key: index, value: rawEntries[index]));
      }
    }

    final defaultScanDepth = _positiveInt(
      source['scan_depth'] ?? source['scanDepth'],
      4,
    );
    final entries = <WorldBookEntry>[];
    var skippedEntries = 0;
    var hasUnsupportedSettings = _hasUnsupportedBookSettings(source);

    for (final indexed in indexedEntries) {
      final raw = _asMap(indexed.value);
      if (raw == null) {
        skippedEntries++;
        continue;
      }

      final converted = _convertSillyTavernEntry(
        raw,
        fallbackId: indexed.key.toString(),
        defaultScanDepth: defaultScanDepth,
      );
      entries.add(converted.entry);
      hasUnsupportedSettings |= converted.hasUnsupportedSettings;
    }

    final name = _string(source['name']).trim();
    final id = _string(source['id']).trim();
    return WorldBookImportResult(
      book: WorldBook(
        id: id,
        name: name.isEmpty ? fallbackName : name,
        description: _string(source['description']),
        enabled: _bool(source['enabled'], true),
        entries: entries,
      ),
      format: WorldBookImportFormat.sillyTavern,
      skippedEntries: skippedEntries,
      hasUnsupportedSettings: hasUnsupportedSettings,
    );
  }

  static ({WorldBookEntry entry, bool hasUnsupportedSettings})
  _convertSillyTavernEntry(
    Map<String, dynamic> raw, {
    required String fallbackId,
    required int defaultScanDepth,
  }) {
    final extensions = _asMap(raw['extensions']) ?? const <String, dynamic>{};
    final keywordValues = _stringList(
      raw['key'] ?? raw['keys'] ?? raw['keywords'],
    );
    final regexConversion = _convertKeywords(keywordValues);

    final rawPosition =
        extensions['position'] ?? raw['position'] ?? raw['injection_position'];
    final position = _position(rawPosition);
    final roleValue = extensions['role'] ?? raw['role'];
    final role = _role(roleValue);
    final scanDepthValue =
        raw['scanDepth'] ?? extensions['scan_depth'] ?? raw['scan_depth'];
    final scanDepth = _positiveInt(scanDepthValue, defaultScanDepth);
    final injectDepth = _positiveInt(
      raw['depth'] ?? extensions['depth'] ?? raw['injectDepth'],
      4,
    );

    final idValue = raw['uid'] ?? raw['id'] ?? fallbackId;
    final rawName = _string(raw['comment'] ?? raw['name']).trim();
    final entryName = rawName.isNotEmpty
        ? rawName
        : (keywordValues.isEmpty ? '' : keywordValues.first);
    final enabled = raw.containsKey('enabled')
        ? _bool(raw['enabled'], true)
        : !_bool(raw['disable'], false);
    final caseSensitiveValue =
        raw['caseSensitive'] ??
        raw['case_sensitive'] ??
        extensions['case_sensitive'];
    var caseSensitive = _bool(caseSensitiveValue, false);
    if (regexConversion.requiresCaseInsensitive) caseSensitive = false;

    final hasUnsupportedSettings =
        regexConversion.hasUnsupportedFlags ||
        _hasUnsupportedEntrySettings(raw, extensions, rawPosition, roleValue);

    return (
      entry: WorldBookEntry(
        id: _string(idValue),
        name: entryName,
        enabled: enabled,
        priority: _int(
          raw['order'] ?? raw['insertion_order'] ?? raw['priority'],
          0,
        ),
        position: position,
        content: _string(raw['content']),
        injectDepth: injectDepth,
        role: role,
        keywords: regexConversion.keywords,
        useRegex: _bool(raw['useRegex'], false) || regexConversion.hasRegex,
        caseSensitive: caseSensitive,
        scanDepth: scanDepth,
        constantActive: _bool(raw['constant'] ?? raw['constantActive'], false),
      ),
      hasUnsupportedSettings: hasUnsupportedSettings,
    );
  }

  static ({
    List<String> keywords,
    bool hasRegex,
    bool requiresCaseInsensitive,
    bool hasUnsupportedFlags,
  })
  _convertKeywords(List<String> keywords) {
    final parsed = keywords.map(_parseRegexLiteral).toList(growable: false);
    final hasRegex = parsed.any((item) => item.isRegex);
    if (!hasRegex) {
      return (
        keywords: keywords,
        hasRegex: false,
        requiresCaseInsensitive: false,
        hasUnsupportedFlags: false,
      );
    }

    return (
      keywords: parsed
          .map(
            (item) => item.isRegex ? item.pattern : RegExp.escape(item.pattern),
          )
          .toList(growable: false),
      hasRegex: true,
      requiresCaseInsensitive: parsed.any((item) => item.flags.contains('i')),
      hasUnsupportedFlags: parsed.any(
        (item) => RegExp(r'[dmsvy]').hasMatch(item.flags),
      ),
    );
  }

  static ({String pattern, String flags, bool isRegex}) _parseRegexLiteral(
    String value,
  ) {
    if (!value.startsWith('/') || value.length < 2) {
      return (pattern: value, flags: '', isRegex: false);
    }

    var closingSlash = -1;
    for (var index = value.length - 1; index > 0; index--) {
      if (value[index] != '/') continue;
      var backslashes = 0;
      for (
        var cursor = index - 1;
        cursor >= 0 && value[cursor] == r'\';
        cursor--
      ) {
        backslashes++;
      }
      if (backslashes.isEven) {
        closingSlash = index;
        break;
      }
    }
    if (closingSlash <= 0) {
      return (pattern: value, flags: '', isRegex: false);
    }

    final flags = value.substring(closingSlash + 1);
    if (!RegExp(r'^[dgimsuvy]*$').hasMatch(flags)) {
      return (pattern: value, flags: '', isRegex: false);
    }
    return (
      pattern: value.substring(1, closingSlash),
      flags: flags,
      isRegex: true,
    );
  }

  static WorldBookInjectionPosition _position(dynamic value) {
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'before_char':
        case 'before_character':
        case 'before_system_prompt':
          return WorldBookInjectionPosition.beforeSystemPrompt;
        case 'at_depth':
          return WorldBookInjectionPosition.atDepth;
        case 'top_of_chat':
          return WorldBookInjectionPosition.topOfChat;
        case 'bottom_of_chat':
          return WorldBookInjectionPosition.bottomOfChat;
        case 'after_char':
        case 'after_character':
        case 'after_system_prompt':
          return WorldBookInjectionPosition.afterSystemPrompt;
      }
    }

    return switch (_int(value, 1)) {
      0 => WorldBookInjectionPosition.beforeSystemPrompt,
      4 => WorldBookInjectionPosition.atDepth,
      5 || 6 => WorldBookInjectionPosition.topOfChat,
      _ => WorldBookInjectionPosition.afterSystemPrompt,
    };
  }

  static WorldBookInjectionRole _role(dynamic value) {
    if (value is String) {
      return value.trim().toLowerCase() == 'assistant'
          ? WorldBookInjectionRole.assistant
          : WorldBookInjectionRole.user;
    }
    return _int(value, 0) == 2
        ? WorldBookInjectionRole.assistant
        : WorldBookInjectionRole.user;
  }

  static bool _hasUnsupportedBookSettings(Map<String, dynamic> source) {
    return _meaningful(source['token_budget']) ||
        _bool(source['recursive_scanning'], false) ||
        _meaningful(source['min_activations']) ||
        _meaningful(source['max_recursion_steps']);
  }

  static bool _hasUnsupportedEntrySettings(
    Map<String, dynamic> raw,
    Map<String, dynamic> extensions,
    dynamic rawPosition,
    dynamic roleValue,
  ) {
    final secondaryKeys = _stringList(
      raw['keysecondary'] ?? raw['secondary_keys'],
    );
    final positionNumber = rawPosition is num
        ? rawPosition.toInt()
        : int.tryParse(_string(rawPosition));
    final roleNumber = roleValue is num
        ? roleValue.toInt()
        : int.tryParse(_string(roleValue));

    return secondaryKeys.isNotEmpty ||
        (positionNumber != null && !const {0, 1, 4}.contains(positionNumber)) ||
        (positionNumber == 4 && (roleNumber ?? 0) == 0) ||
        _bool(raw['vectorized'] ?? extensions['vectorized'], false) ||
        _bool(
          raw['excludeRecursion'] ?? extensions['exclude_recursion'],
          false,
        ) ||
        _bool(
          raw['preventRecursion'] ?? extensions['prevent_recursion'],
          false,
        ) ||
        _meaningful(
          raw['delayUntilRecursion'] ?? extensions['delay_until_recursion'],
        ) ||
        _meaningful(raw['group'] ?? extensions['group']) ||
        _bool(raw['groupOverride'] ?? extensions['group_override'], false) ||
        _meaningful(raw['sticky'] ?? extensions['sticky']) ||
        _meaningful(raw['cooldown'] ?? extensions['cooldown']) ||
        _meaningful(raw['delay'] ?? extensions['delay']) ||
        _meaningful(raw['automationId'] ?? extensions['automation_id']) ||
        _meaningful(raw['triggers'] ?? extensions['triggers']) ||
        _bool(raw['ignoreBudget'] ?? extensions['ignore_budget'], false) ||
        _bool(
          raw['matchWholeWords'] ?? extensions['match_whole_words'],
          false,
        ) ||
        (_bool(raw['useProbability'] ?? extensions['useProbability'], true) &&
            _int(raw['probability'] ?? extensions['probability'], 100) !=
                100) ||
        _meaningful(raw['characterFilter'] ?? raw['character_filter']);
  }

  static WorldBook _withFallbackName(WorldBook book, String fallbackName) {
    if (book.name.trim().isNotEmpty || fallbackName.trim().isEmpty) return book;
    return book.copyWith(name: fallbackName.trim());
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  static List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .map(_string)
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    if (value is String) {
      return value
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }

  static String _string(dynamic value) => value?.toString() ?? '';

  static bool _bool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'true':
        case '1':
          return true;
        case 'false':
        case '0':
          return false;
      }
    }
    return fallback;
  }

  static int _int(dynamic value, int fallback) {
    if (value is num) return value.toInt();
    return int.tryParse(_string(value)) ?? fallback;
  }

  static int _positiveInt(dynamic value, int fallback) {
    final parsed = _int(value, fallback);
    return parsed <= 0 ? 1 : parsed;
  }

  static bool _meaningful(dynamic value) {
    if (value == null || value == false) return false;
    if (value is num) return value != 0;
    if (value is String) return value.trim().isNotEmpty;
    if (value is Iterable) return value.isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    return true;
  }
}
