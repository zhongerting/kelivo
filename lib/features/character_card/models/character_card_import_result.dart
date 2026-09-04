import 'dart:typed_data';

import '../../../core/models/assistant.dart';
import '../../../core/models/world_book.dart';

enum CharacterCardSourceFormat { jsonV1, jsonV2, jsonV3, png }

class CharacterCardAssistantDraft {
  const CharacterCardAssistantDraft({
    required this.name,
    required this.characterPrompt,
    required this.firstMessage,
    this.avatarBytes,
    this.avatarMimeType = 'image/png',
  });

  final String name;
  final String characterPrompt;
  final String firstMessage;
  final Uint8List? avatarBytes;
  final String avatarMimeType;

  Assistant toAssistant({required String id, String? avatar}) {
    return Assistant(
      id: id,
      name: name,
      avatar: avatar,
      useAssistantAvatar: avatar != null && avatar.isNotEmpty,
      mode: AssistantMode.roleplay,
      characterPrompt: characterPrompt,
      firstMessage: firstMessage,
      excludeThinkingFromContext: true,
    );
  }
}

class CharacterCardWorldBookEntryDraft {
  const CharacterCardWorldBookEntryDraft({
    required this.name,
    required this.content,
    required this.keywords,
    required this.enabled,
    required this.priority,
    required this.position,
    required this.injectDepth,
    required this.role,
    required this.caseSensitive,
    required this.scanDepth,
    required this.constantActive,
    this.requiresDisable = false,
    this.warnings = const <String>[],
  });

  final String name;
  final String content;
  final List<String> keywords;
  final bool enabled;
  final int priority;
  final WorldBookInjectionPosition position;
  final int injectDepth;
  final WorldBookInjectionRole role;
  final bool caseSensitive;
  final int scanDepth;
  final bool constantActive;
  final bool requiresDisable;
  final List<String> warnings;
}

class CharacterCardWorldBookDraft {
  const CharacterCardWorldBookDraft({
    required this.name,
    required this.description,
    required this.enabled,
    required this.entries,
    this.warnings = const <String>[],
    this.skippedEntryCount = 0,
  });

  final String name;
  final String description;
  final bool enabled;
  final List<CharacterCardWorldBookEntryDraft> entries;
  final List<String> warnings;
  final int skippedEntryCount;

  int get enabledEntryCount =>
      entries.where((entry) => entry.enabled && !entry.requiresDisable).length;

  int get disabledEntryCount =>
      entries.where((entry) => !entry.enabled || entry.requiresDisable).length;
}

class CharacterCardImportResult {
  const CharacterCardImportResult({
    required this.assistantDraft,
    required this.sourceFormat,
    required this.specVersion,
    required this.importedFields,
    required this.ignoredFields,
    this.ignoredFieldCounts = const <String, int>{},
    required this.warnings,
    this.embeddedWorldBook,
    this.disabledWorldBookEntries = 0,
    this.skippedWorldBookEntries = 0,
    this.sourceFileName = '',
  });

  final CharacterCardAssistantDraft assistantDraft;
  final CharacterCardSourceFormat sourceFormat;
  final String specVersion;
  final List<String> importedFields;
  final List<String> ignoredFields;
  final Map<String, int> ignoredFieldCounts;
  final List<String> warnings;
  final CharacterCardWorldBookDraft? embeddedWorldBook;
  final int disabledWorldBookEntries;
  final int skippedWorldBookEntries;
  final String sourceFileName;

  int get totalWorldBookEntries => embeddedWorldBook == null
      ? 0
      : embeddedWorldBook!.entries.length + skippedWorldBookEntries;

  int get enabledWorldBookEntries => embeddedWorldBook?.enabledEntryCount ?? 0;

  CharacterCardImportResult copyWith({
    CharacterCardAssistantDraft? assistantDraft,
    CharacterCardSourceFormat? sourceFormat,
    String? specVersion,
    List<String>? importedFields,
    List<String>? ignoredFields,
    Map<String, int>? ignoredFieldCounts,
    List<String>? warnings,
    CharacterCardWorldBookDraft? embeddedWorldBook,
    int? disabledWorldBookEntries,
    int? skippedWorldBookEntries,
    String? sourceFileName,
  }) {
    return CharacterCardImportResult(
      assistantDraft: assistantDraft ?? this.assistantDraft,
      sourceFormat: sourceFormat ?? this.sourceFormat,
      specVersion: specVersion ?? this.specVersion,
      importedFields: importedFields ?? this.importedFields,
      ignoredFields: ignoredFields ?? this.ignoredFields,
      ignoredFieldCounts: ignoredFieldCounts ?? this.ignoredFieldCounts,
      warnings: warnings ?? this.warnings,
      embeddedWorldBook: embeddedWorldBook ?? this.embeddedWorldBook,
      disabledWorldBookEntries:
          disabledWorldBookEntries ?? this.disabledWorldBookEntries,
      skippedWorldBookEntries:
          skippedWorldBookEntries ?? this.skippedWorldBookEntries,
      sourceFileName: sourceFileName ?? this.sourceFileName,
    );
  }
}
