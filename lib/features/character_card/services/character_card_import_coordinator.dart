import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/world_book.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../utils/app_directories.dart';
import '../models/character_card_import_result.dart';
import 'character_card_import_service.dart';

class CharacterCardImportCommitResult {
  const CharacterCardImportCommitResult({
    required this.parsed,
    required this.assistant,
    this.worldBook,
  });

  final CharacterCardImportResult parsed;
  final Assistant assistant;
  final WorldBook? worldBook;
}

/// Commits a parsed card as one RP assistant and, when present, one bound
/// world book. Each write is followed by compensating cleanup on failure.
class CharacterCardImportCoordinator {
  CharacterCardImportCoordinator({
    required this.assistantProvider,
    required this.worldBookProvider,
  });

  final AssistantProvider assistantProvider;
  final WorldBookProvider worldBookProvider;

  Future<CharacterCardImportCommitResult> importFile(
    File file, {
    String? sourceFileName,
  }) async {
    final parsed = await CharacterCardImportService.parseFile(
      file,
      sourceFileName: sourceFileName,
    );
    return commit(parsed);
  }

  Future<CharacterCardImportCommitResult> commit(
    CharacterCardImportResult parsed,
  ) async {
    await assistantProvider.loaded;
    await worldBookProvider.initialize();
    final previousAssistantId = assistantProvider.currentAssistantId;
    final assistantId = const Uuid().v4();
    final bookDraft = parsed.embeddedWorldBook;
    final worldBookId = bookDraft == null || bookDraft.entries.isEmpty
        ? null
        : const Uuid().v4();
    String? avatarPath;
    try {
      avatarPath = await _saveAvatar(
        parsed.assistantDraft.avatarBytes,
        assistantId: assistantId,
      );
      final assistant = parsed.assistantDraft.toAssistant(
        id: assistantId,
        avatar: avatarPath,
      );
      await assistantProvider.addAssistantObject(assistant, select: true);

      final WorldBook? worldBook;
      if (bookDraft == null || bookDraft.entries.isEmpty) {
        worldBook = null;
      } else {
        worldBook = _toWorldBook(
          bookDraft,
          assistantName: assistant.name,
          bookId: worldBookId!,
        );
        await worldBookProvider.addBook(worldBook);
        final existing = worldBookProvider.activeBookIdsFor(assistant.id);
        await worldBookProvider.setActiveBookIds([
          ...existing,
          worldBook.id,
        ], assistantId: assistant.id);
      }
      return CharacterCardImportCommitResult(
        parsed: parsed,
        assistant: assistant,
        worldBook: worldBook,
      );
    } catch (error, stackTrace) {
      final rollbackErrors = <String>[];
      if (worldBookId != null) {
        try {
          final activeIds = worldBookProvider.activeBookIdsFor(assistantId);
          if (activeIds.contains(worldBookId)) {
            await worldBookProvider.setActiveBookIds(
              activeIds
                  .where((id) => id != worldBookId)
                  .toList(growable: false),
              assistantId: assistantId,
            );
          }
        } catch (rollbackError) {
          rollbackErrors.add('world-book binding: $rollbackError');
        }
        try {
          if (worldBookProvider.getById(worldBookId) != null) {
            await worldBookProvider.deleteBook(worldBookId);
          }
        } catch (rollbackError) {
          rollbackErrors.add('world-book: $rollbackError');
        }
      }
      try {
        await assistantProvider.removeAssistantObject(assistantId);
      } catch (rollbackError) {
        rollbackErrors.add('assistant: $rollbackError');
      }
      try {
        await assistantProvider.restoreCurrentAssistantId(previousAssistantId);
      } catch (rollbackError) {
        rollbackErrors.add('current assistant: $rollbackError');
      }
      try {
        await _deleteAvatar(avatarPath);
      } catch (rollbackError) {
        rollbackErrors.add('avatar: $rollbackError');
      }

      final importError = error is CharacterCardImportException
          ? error
          : CharacterCardImportException(
              'Unable to save the imported character card: $error',
            );
      if (rollbackErrors.isEmpty) {
        Error.throwWithStackTrace(importError, stackTrace);
      }
      Error.throwWithStackTrace(
        CharacterCardImportException(
          '${importError.message} Rollback also failed: '
          '${rollbackErrors.join('; ')}',
        ),
        stackTrace,
      );
    }
  }

  static WorldBook _toWorldBook(
    CharacterCardWorldBookDraft draft, {
    required String assistantName,
    required String bookId,
  }) {
    final name = draft.name.trim().isEmpty
        ? '$assistantName - World Book'
        : draft.name.trim();
    return WorldBook(
      id: bookId,
      name: name,
      description: draft.description,
      enabled: draft.enabled,
      entries: [
        for (final entry in draft.entries)
          WorldBookEntry(
            id: const Uuid().v4(),
            name: entry.name,
            enabled: entry.enabled,
            priority: entry.priority,
            position: entry.position,
            content: entry.content,
            injectDepth: entry.injectDepth,
            role: entry.role,
            keywords: entry.keywords,
            useRegex: false,
            caseSensitive: entry.caseSensitive,
            scanDepth: entry.scanDepth,
            constantActive: entry.constantActive,
          ),
      ],
    );
  }

  static Future<String?> _saveAvatar(
    Uint8List? bytes, {
    required String assistantId,
  }) async {
    if (bytes == null || bytes.isEmpty) return null;
    final dir = await AppDirectories.getAvatarsDirectory();
    await dir.create(recursive: true);
    final safeId = assistantId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final path = p.join(
      dir.path,
      'assistant_${safeId}_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    final temporaryPath = '$path.part';
    final temporaryFile = File(temporaryPath);
    try {
      await temporaryFile.writeAsBytes(bytes, flush: true);
      await temporaryFile.rename(path);
      return path;
    } catch (_) {
      try {
        if (await temporaryFile.exists()) await temporaryFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  static Future<void> _deleteAvatar(String? path) async {
    if (path == null || path.isEmpty) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
