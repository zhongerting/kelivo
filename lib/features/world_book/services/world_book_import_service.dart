import 'dart:convert';

import '../../../core/models/world_book.dart';

enum WorldBookImportFormat { kelivo, sillyTavern }

/// Conversion policy selected by the caller. The ordinary world-book importer
/// keeps its existing regex support; character cards use a stricter policy
/// because their entries are untrusted and must never widen trigger scope.
enum WorldBookImportPolicy { standard, characterCard }

class WorldBookImportResult {
  const WorldBookImportResult({
    required this.book,
    required this.format,
    this.skippedEntries = 0,
    this.hasUnsupportedSettings = false,
    this.warnings = const <String>[],
  });

  final WorldBook book;
  final WorldBookImportFormat format;
  final int skippedEntries;
  final bool hasUnsupportedSettings;
  final List<String> warnings;
}

class WorldBookImportService {
  const WorldBookImportService._();

  static const int maxCharacterCardEntries = 10000;
  static const int maxCharacterCardEntryContentBytes = 2 * 1024 * 1024;

  static WorldBookImportResult? parse(
    dynamic decoded, {
    String fallbackName = '',
    WorldBookImportPolicy policy = WorldBookImportPolicy.standard,
  }) {
    if (decoded is! Map) return null;

    try {
      final root = decoded.cast<String, dynamic>();
      final source = _findBookSource(root);
      if (source == null) return null;

      if (policy == WorldBookImportPolicy.characterCard ||
          _isSillyTavernBook(source)) {
        return _parseSillyTavern(
          source,
          fallbackName: fallbackName,
          policy: policy,
        );
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
    required WorldBookImportPolicy policy,
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

    final rawEntryCount = indexedEntries.length;
    if (policy == WorldBookImportPolicy.characterCard &&
        rawEntries is! List &&
        rawEntries is! Map) {
      return WorldBookImportResult(
        book: WorldBook(
          id: '',
          name: _characterCardString(source['name']).trim(),
          description: _characterCardString(source['description']),
          enabled: _bool(source['enabled'], true),
        ),
        format: WorldBookImportFormat.sillyTavern,
        warnings: const <String>[
          'Embedded character_book entries were not an array or object.',
        ],
      );
    }

    final defaultScanDepth = _positiveInt(
      source['scan_depth'] ?? source['scanDepth'],
      4,
    );
    final entries = <WorldBookEntry>[];
    final warnings = <String>[];
    var skippedEntries = 0;
    var hasUnsupportedSettings = _hasUnsupportedBookSettings(source);
    if (policy == WorldBookImportPolicy.characterCard &&
        hasUnsupportedSettings) {
      warnings.add(
        'Unsupported world-book recursion or budget settings disabled entries.',
      );
    }

    final entriesToRead = policy == WorldBookImportPolicy.characterCard
        ? indexedEntries.take(maxCharacterCardEntries)
        : indexedEntries;
    for (final indexed in entriesToRead) {
      final raw = _asMap(indexed.value);
      if (raw == null) {
        skippedEntries++;
        continue;
      }

      if (policy == WorldBookImportPolicy.characterCard) {
        final content = raw['content'];
        if (content is! String ||
            content.isEmpty ||
            utf8.encode(content).length > maxCharacterCardEntryContentBytes) {
          skippedEntries++;
          continue;
        }
      }

      late final WorldBookEntry convertedEntry;
      late final bool convertedHasUnsupportedSettings;
      if (policy == WorldBookImportPolicy.characterCard) {
        final converted = _convertCharacterCardEntry(
          raw,
          fallbackId: indexed.key.toString(),
          defaultScanDepth: defaultScanDepth,
        );
        convertedEntry = converted.entry;
        convertedHasUnsupportedSettings = converted.hasUnsupportedSettings;
        warnings.addAll(converted.warnings);
      } else {
        final converted = _convertSillyTavernEntry(
          raw,
          fallbackId: indexed.key.toString(),
          defaultScanDepth: defaultScanDepth,
        );
        convertedEntry = converted.entry;
        convertedHasUnsupportedSettings = converted.hasUnsupportedSettings;
      }
      entries.add(convertedEntry);
      hasUnsupportedSettings |= convertedHasUnsupportedSettings;
    }

    if (policy == WorldBookImportPolicy.characterCard &&
        rawEntryCount > maxCharacterCardEntries) {
      skippedEntries += rawEntryCount - maxCharacterCardEntries;
      warnings.add(
        '${rawEntryCount - maxCharacterCardEntries} extra world-book entries were skipped by the safety limit.',
      );
    }
    if (policy == WorldBookImportPolicy.characterCard && skippedEntries > 0) {
      warnings.add('$skippedEntries world-book entries were skipped.');
    }

    final name = policy == WorldBookImportPolicy.characterCard
        ? _characterCardString(source['name']).trim()
        : _string(source['name']).trim();
    final id = policy == WorldBookImportPolicy.characterCard
        ? _characterCardString(source['id']).trim()
        : _string(source['id']).trim();
    return WorldBookImportResult(
      book: WorldBook(
        id: id,
        name: name.isEmpty ? fallbackName : name,
        description: policy == WorldBookImportPolicy.characterCard
            ? _characterCardString(source['description'])
            : _string(source['description']),
        enabled: _bool(source['enabled'], true),
        entries: entries,
      ),
      format: WorldBookImportFormat.sillyTavern,
      skippedEntries: skippedEntries,
      hasUnsupportedSettings: hasUnsupportedSettings,
      warnings: _unique(warnings),
    );
  }

  static ({
    WorldBookEntry entry,
    bool hasUnsupportedSettings,
    List<String> warnings,
  })
  _convertCharacterCardEntry(
    Map<String, dynamic> raw, {
    required String fallbackId,
    required int defaultScanDepth,
  }) {
    final extensions = _asMap(raw['extensions']) ?? const <String, dynamic>{};
    final rawKeys = _characterCardStringList(
      raw['keys'] ?? raw['key'] ?? raw['keywords'],
    );
    final explicitRegex = _bool(
      raw['use_regex'] ?? raw['useRegex'] ?? extensions['use_regex'],
      false,
    );
    final ordinaryKeys = <String>[];
    final regexKeys = <String>[];
    for (final key in rawKeys) {
      if (explicitRegex || _parseRegexLiteral(key).isRegex) {
        regexKeys.add(key);
      } else {
        ordinaryKeys.add(key);
      }
    }
    final regexOnly = ordinaryKeys.isEmpty && regexKeys.isNotEmpty;
    final mixed = ordinaryKeys.isNotEmpty && regexKeys.isNotEmpty;

    final rawPosition =
        extensions['position'] ?? raw['position'] ?? raw['injection_position'];
    final positionResult = _characterCardPosition(rawPosition);
    final roleValue = extensions['role'] ?? raw['role'];
    final role = _role(roleValue);
    final advanced =
        _hasUnsupportedCharacterCardExtensions(extensions) ||
        _hasUnsupportedCharacterCardEntrySettings(
          raw,
          extensions,
          rawPosition,
          roleValue,
          position: positionResult.position,
        ) ||
        !positionResult.supported;
    final warnings = <String>[];
    if (regexOnly) {
      warnings.add('Regular-expression-only keywords were disabled.');
    }
    if (mixed) {
      warnings.add(
        'Regular-expression keywords were discarded; ordinary keywords were kept.',
      );
    }
    if (advanced) {
      warnings.add('Unsupported world-book conditions were disabled.');
    }

    final sourceEnabled = raw.containsKey('enabled')
        ? _bool(raw['enabled'], true)
        : !_bool(raw['disable'], false);
    final disabled = !sourceEnabled || regexOnly || advanced;
    final content = _string(raw['content']);
    final rawName = _string(raw['comment'] ?? raw['name']).trim();
    final entryName = rawName.isNotEmpty
        ? rawName
        : (rawKeys.isEmpty ? '' : rawKeys.first);
    return (
      entry: WorldBookEntry(
        id: _string(raw['uid'] ?? raw['id'] ?? fallbackId),
        name: entryName,
        enabled: !disabled,
        priority: _int(
          raw['insertion_order'] ?? raw['order'] ?? raw['priority'],
          0,
        ),
        position: positionResult.position,
        content: content,
        injectDepth: _positiveInt(
          raw['depth'] ?? extensions['depth'] ?? raw['injectDepth'],
          4,
        ),
        role: role,
        keywords: List.unmodifiable(ordinaryKeys),
        useRegex: false,
        caseSensitive: _bool(
          raw['case_sensitive'] ??
              raw['caseSensitive'] ??
              extensions['case_sensitive'],
          false,
        ),
        scanDepth: _positiveInt(
          raw['scan_depth'] ?? raw['scanDepth'] ?? extensions['scan_depth'],
          defaultScanDepth,
        ),
        constantActive: _bool(raw['constant'] ?? raw['constantActive'], false),
      ),
      hasUnsupportedSettings: advanced,
      warnings: List.unmodifiable(warnings),
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

  static ({WorldBookInjectionPosition position, bool supported})
  _characterCardPosition(dynamic value) {
    if (value == null) {
      return (
        position: WorldBookInjectionPosition.afterSystemPrompt,
        supported: true,
      );
    }
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'before_char':
        case 'before_character':
        case 'before_system_prompt':
          return (
            position: WorldBookInjectionPosition.beforeSystemPrompt,
            supported: true,
          );
        case 'after_char':
        case 'after_character':
        case 'after_system_prompt':
          return (
            position: WorldBookInjectionPosition.afterSystemPrompt,
            supported: true,
          );
        case 'top_of_chat':
        case 'top':
          return (
            position: WorldBookInjectionPosition.topOfChat,
            supported: true,
          );
        case 'bottom_of_chat':
        case 'bottom':
          return (
            position: WorldBookInjectionPosition.bottomOfChat,
            supported: true,
          );
        case 'at_depth':
        case 'depth':
          return (
            position: WorldBookInjectionPosition.atDepth,
            supported: true,
          );
        default:
          return (
            position: WorldBookInjectionPosition.afterSystemPrompt,
            supported: false,
          );
      }
    }
    return switch (_intOrNull(value)) {
      0 => (
        position: WorldBookInjectionPosition.beforeSystemPrompt,
        supported: true,
      ),
      1 => (
        position: WorldBookInjectionPosition.afterSystemPrompt,
        supported: true,
      ),
      4 => (position: WorldBookInjectionPosition.atDepth, supported: true),
      5 => (position: WorldBookInjectionPosition.topOfChat, supported: true),
      6 => (position: WorldBookInjectionPosition.bottomOfChat, supported: true),
      _ => (
        position: WorldBookInjectionPosition.afterSystemPrompt,
        supported: false,
      ),
    };
  }

  static bool _hasUnsupportedCharacterCardExtensions(
    Map<String, dynamic> extensions,
  ) {
    const knownExtensionKeys = <String>{
      'position',
      'role',
      'depth',
      'scan_depth',
      'scanDepth',
      'case_sensitive',
      'caseSensitive',
      'use_regex',
      'useRegex',
      'probability',
      'useProbability',
      'use_probability',
      'vectorized',
      'exclude_recursion',
      'excludeRecursion',
      'prevent_recursion',
      'preventRecursion',
      'delay_until_recursion',
      'delayUntilRecursion',
      'automation_id',
      'automationId',
      'group',
      'group_weight',
      'groupWeight',
      'group_override',
      'groupOverride',
      'sticky',
      'cooldown',
      'delay',
      'triggers',
      'ignore_budget',
      'ignoreBudget',
      'match_whole_words',
      'matchWholeWords',
      'character_filter',
      'characterFilter',
      // These fields are UI/source metadata and never affect matching.
      'display_index',
      'displayIndex',
      'uid',
      'id',
      'name',
      'comment',
    };
    return extensions.entries.any(
      (entry) =>
          !knownExtensionKeys.contains(entry.key) && _meaningful(entry.value),
    );
  }

  static bool _hasUnsupportedCharacterCardEntrySettings(
    Map<String, dynamic> entry,
    Map<String, dynamic> extensions,
    dynamic rawPosition,
    dynamic roleValue, {
    required WorldBookInjectionPosition position,
  }) {
    final secondary = _characterCardStringList(
      entry['keysecondary'] ??
          entry['secondary_keys'] ??
          entry['secondaryKeys'] ??
          entry['secondary_key'],
    );
    final positionNumber = _intOrNull(rawPosition);
    final probability = entry['probability'] ?? extensions['probability'];
    final probabilityEnabled =
        entry['useProbability'] ??
        entry['use_probability'] ??
        extensions['useProbability'] ??
        extensions['use_probability'];
    final probabilityIsEnabled = _bool(probabilityEnabled, true);
    final selectiveLogic =
        entry['selectiveLogic'] ??
        entry['selective_logic'] ??
        extensions['selectiveLogic'] ??
        extensions['selective_logic'];
    return secondary.isNotEmpty ||
        _meaningful(entry['and']) ||
        _meaningful(entry['not']) ||
        _meaningful(entry['logic']) ||
        (selectiveLogic != null && _int(selectiveLogic, 0) != 0) ||
        (probabilityIsEnabled &&
            probability != null &&
            _int(probability, 100) != 100) ||
        _bool(entry['vectorized'] ?? extensions['vectorized'], false) ||
        _bool(
          entry['exclude_recursion'] ??
              entry['excludeRecursion'] ??
              extensions['exclude_recursion'] ??
              extensions['excludeRecursion'],
          false,
        ) ||
        _bool(
          entry['prevent_recursion'] ??
              entry['preventRecursion'] ??
              extensions['prevent_recursion'] ??
              extensions['preventRecursion'],
          false,
        ) ||
        _meaningful(
          entry['delay_until_recursion'] ??
              entry['delayUntilRecursion'] ??
              extensions['delay_until_recursion'] ??
              extensions['delayUntilRecursion'],
        ) ||
        _meaningful(
          entry['automation_id'] ??
              entry['automationId'] ??
              extensions['automation_id'] ??
              extensions['automationId'],
        ) ||
        _meaningful(entry['group'] ?? extensions['group']) ||
        (_int(
              entry['group_weight'] ??
                  entry['groupWeight'] ??
                  extensions['group_weight'] ??
                  extensions['groupWeight'],
              100,
            ) !=
            100) ||
        _bool(
          entry['group_override'] ??
              entry['groupOverride'] ??
              extensions['group_override'] ??
              extensions['groupOverride'],
          false,
        ) ||
        _meaningful(entry['sticky'] ?? extensions['sticky']) ||
        _meaningful(entry['cooldown'] ?? extensions['cooldown']) ||
        _meaningful(entry['delay'] ?? extensions['delay']) ||
        _meaningful(entry['triggers'] ?? extensions['triggers']) ||
        _bool(
          entry['ignore_budget'] ??
              entry['ignoreBudget'] ??
              extensions['ignore_budget'] ??
              extensions['ignoreBudget'],
          false,
        ) ||
        _bool(
          entry['match_whole_words'] ??
              entry['matchWholeWords'] ??
              extensions['match_whole_words'] ??
              extensions['matchWholeWords'],
          false,
        ) ||
        _hasNonEmptyCharacterFilter(
          entry['character_filter'] ??
              entry['characterFilter'] ??
              extensions['character_filter'] ??
              extensions['characterFilter'],
        ) ||
        (positionNumber != null &&
            !const {0, 1, 4, 5, 6}.contains(positionNumber)) ||
        !_isSupportedCharacterCardRole(roleValue, position: position);
  }

  static bool _isSupportedCharacterCardRole(
    dynamic value, {
    required WorldBookInjectionPosition position,
  }) {
    if (value == null) return true;
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'user':
        case '1':
        case 'assistant':
        case '2':
          return true;
        case '0':
          return position != WorldBookInjectionPosition.atDepth;
        default:
          return false;
      }
    }
    if (value is num && value.toInt() == 0) {
      return position != WorldBookInjectionPosition.atDepth;
    }
    return value is num && (value.toInt() == 1 || value.toInt() == 2);
  }

  static bool _hasNonEmptyCharacterFilter(dynamic value) {
    if (value == null || value == false) return false;
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().trim().toLowerCase();
        if (key == 'isexclude' || key == 'is_exclude') continue;
        if (_meaningful(entry.value)) return true;
      }
      return false;
    }
    return _meaningful(value);
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

  static List<String> _characterCardStringList(dynamic value) {
    if (value is List) {
      return value
          .whereType<String>()
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

  static int? _intOrNull(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(_string(value));
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

  static String _characterCardString(dynamic value) =>
      value is String ? value : '';

  static List<String> _unique(Iterable<String> values) => values
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList(growable: false);
}
