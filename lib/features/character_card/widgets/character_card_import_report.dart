import 'dart:io' show File;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../features/home/widgets/assistant_avatar.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../services/character_card_import_coordinator.dart';
import '../services/character_card_import_service.dart';

/// Opens the platform picker, commits a safe character-card import, and shows
/// the full import report. The assistant is selected by the coordinator before
/// the report is displayed.
Future<CharacterCardImportCommitResult?> importCharacterCardFromPicker(
  BuildContext context,
) async {
  final l10n = AppLocalizations.of(context)!;
  FilePickerResult? picked;
  try {
    picked = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: true,
      type: FileType.custom,
      allowedExtensions: const ['json', 'png'],
    );
  } on Exception catch (error) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: l10n.characterCardImportFailed(error.toString()),
        type: NotificationType.error,
      );
    }
    return null;
  }
  if (picked == null || picked.files.isEmpty) return null;
  if (!context.mounted) return null;

  final file = picked.files.first;
  try {
    final coordinator = CharacterCardImportCoordinator(
      assistantProvider: context.read<AssistantProvider>(),
      worldBookProvider: context.read<WorldBookProvider>(),
    );
    final committed = await _commitPickedFile(coordinator, file);
    if (!context.mounted) return committed;
    await showCharacterCardImportReport(context, committed);
    return committed;
  } on CharacterCardImportException catch (error) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: l10n.characterCardImportFailed(error.message),
        type: NotificationType.error,
      );
    }
  } on Exception catch (error) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: l10n.characterCardImportFailed(error.toString()),
        type: NotificationType.error,
      );
    }
  }
  return null;
}

Future<CharacterCardImportCommitResult> _commitPickedFile(
  CharacterCardImportCoordinator coordinator,
  PlatformFile file,
) async {
  final name = p.basename(
    file.name.trim().isEmpty ? 'character-card' : file.name,
  );
  final bytes = file.bytes;
  if (bytes != null && bytes.isNotEmpty) {
    final parsed = _isPng(bytes)
        ? CharacterCardImportService.parsePngBytes(
            Uint8List.fromList(bytes),
            fallbackName: p.basenameWithoutExtension(name),
            sourceFileName: name,
          )
        : CharacterCardImportService.parseJsonBytes(
            Uint8List.fromList(bytes),
            fallbackName: p.basenameWithoutExtension(name),
            sourceFileName: name,
          );
    return coordinator.commit(parsed);
  }

  final path = file.path;
  if (path == null || path.trim().isEmpty) {
    throw const CharacterCardImportException(
      'The selected character-card file is not readable.',
    );
  }
  return coordinator.importFile(File(path), sourceFileName: name);
}

bool _isPng(List<int> bytes) {
  const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}

Future<void> showCharacterCardImportReport(
  BuildContext context,
  CharacterCardImportCommitResult result,
) {
  final l10n = AppLocalizations.of(context)!;
  final parsed = result.parsed;
  final assistant = result.assistant;
  final imported = parsed.importedFields.toSet();

  Widget statusRow(String label, bool present) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            present ? Lucide.Check : Lucide.Minus,
            size: 17,
            color: present ? cs.primary : cs.onSurface.withValues(alpha: 0.45),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }

  Widget sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 5),
    child: Text(
      title,
      style: TextStyle(fontWeight: AppFontWeights.semibold, fontSize: 13.5),
    ),
  );

  Widget lines(Iterable<String> values, String empty) {
    final items = values.toList(growable: false);
    return Text(
      items.isEmpty ? empty : items.map((value) => '• $value').join('\n'),
      style: TextStyle(
        fontSize: 12.5,
        height: 1.4,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.78),
      ),
    );
  }

  Widget ignoredLines() {
    final items = parsed.ignoredFields;
    return lines(
      items.map((value) {
        final count = parsed.ignoredFieldCounts[value] ?? 1;
        return count > 1 ? '$value ($count)' : value;
      }),
      l10n.characterCardImportNone,
    );
  }

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Row(
        children: [
          AssistantAvatar(assistant: assistant, size: 42),
          const SizedBox(width: 12),
          Expanded(child: Text(l10n.characterCardImportReportTitle)),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                assistant.name,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: AppFontWeights.emphasis,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                l10n.characterCardImportSource(
                  parsed.sourceFormat.name,
                  parsed.specVersion.isEmpty ? '-' : parsed.specVersion,
                ),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.62),
                ),
              ),
              sectionTitle(l10n.characterCardImportFieldsTitle),
              statusRow(
                l10n.characterCardImportCharacterPrompt,
                imported.contains('description') ||
                    imported.contains('personality') ||
                    imported.contains('scenario'),
              ),
              statusRow(
                l10n.characterCardImportFirstMessage,
                imported.contains('first_mes'),
              ),
              statusRow(
                l10n.characterCardImportWorldBook,
                result.worldBook != null,
              ),
              sectionTitle(l10n.characterCardImportIgnoredFields),
              ignoredLines(),
              sectionTitle(l10n.characterCardImportWorldBookSummaryTitle),
              Text(
                l10n.characterCardImportWorldBookSummary(
                  parsed.totalWorldBookEntries,
                  parsed.enabledWorldBookEntries,
                  parsed.disabledWorldBookEntries,
                  parsed.skippedWorldBookEntries,
                ),
                style: const TextStyle(fontSize: 12.5, height: 1.4),
              ),
              sectionTitle(l10n.characterCardImportWarnings),
              lines(parsed.warnings, l10n.characterCardImportNone),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.characterCardImportClose),
        ),
      ],
    ),
  );
}
