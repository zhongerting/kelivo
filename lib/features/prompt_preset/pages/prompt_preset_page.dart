import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/prompt_preset.dart';
import '../../../core/providers/prompt_preset_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../services/prompt_preset_import_service.dart';

class PromptPresetPage extends StatelessWidget {
  const PromptPresetPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IconButton(
            tooltip: l10n.settingsPageBackButton,
            icon: const Icon(Lucide.ArrowLeft),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.promptPresetTitle),
      ),
      body: const PromptPresetManagementView(),
    );
  }
}

/// Shared management surface for the mobile page and the desktop settings
/// pane. The surface owns no navigation chrome, so the desktop pane never
/// needs a bottom sheet or a nested route.
class PromptPresetManagementView extends StatefulWidget {
  const PromptPresetManagementView({super.key});

  @override
  State<PromptPresetManagementView> createState() =>
      _PromptPresetManagementViewState();
}

class _PromptPresetManagementViewState
    extends State<PromptPresetManagementView> {
  final Set<String> _expandedPresetIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PromptPresetProvider>().initialize();
    });
  }

  Future<String?> _readPickedFileAsString(PlatformFile file) async {
    final bytes = file.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    final path = file.path;
    if (path == null || path.isEmpty || kIsWeb) return null;
    try {
      return await File(path).readAsString();
    } on FileSystemException {
      final raw = await File(path).readAsBytes();
      return utf8.decode(raw, allowMalformed: true);
    }
  }

  PromptPreset _normalizeImportedPreset(
    PromptPreset preset, {
    required Set<String> existingPresetIds,
  }) {
    var presetId = preset.id.trim();
    if (presetId.isEmpty || existingPresetIds.contains(presetId)) {
      presetId = const Uuid().v4();
    }
    final entryIds = <String>{};
    final entries = <PromptPresetEntry>[];
    for (final entry in preset.entries) {
      var entryId = entry.id.trim();
      if (entryId.isEmpty || !entryIds.add(entryId)) {
        entryId = const Uuid().v4();
      }
      entries.add(entry.copyWith(id: entryId));
    }
    return preset.copyWith(id: presetId, entries: entries);
  }

  Future<void> _importFromFiles() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
    } on PlatformException {
      return;
    }
    if (!mounted || picked == null || picked.files.isEmpty) return;

    final provider = context.read<PromptPresetProvider>();
    await provider.initialize();
    final reports = <({String fileName, PromptPresetImportResult? result})>[];
    final existingIds = provider.presets.map((preset) => preset.id).toSet();
    for (final file in picked.files) {
      final fileName = file.name.trim().isEmpty ? 'preset.json' : file.name;
      final content = await _readPickedFileAsString(file);
      if (content == null || content.trim().isEmpty) {
        reports.add((fileName: fileName, result: null));
        continue;
      }
      dynamic decoded;
      try {
        decoded = jsonDecode(content);
      } on FormatException {
        reports.add((fileName: fileName, result: null));
        continue;
      }
      final result = PromptPresetImportService.parse(
        decoded,
        fallbackName: fileName.replaceFirst(
          RegExp(r'\.json$', caseSensitive: false),
          '',
        ),
      );
      if (result == null) {
        reports.add((fileName: fileName, result: null));
        continue;
      }
      final normalized = _normalizeImportedPreset(
        result.preset,
        existingPresetIds: existingIds,
      );
      existingIds.add(normalized.id);
      await provider.addPreset(normalized);
      _expandedPresetIds.add(normalized.id);
      reports.add((fileName: fileName, result: result));
    }
    if (!mounted) return;
    await _showImportReport(reports);
  }

  Future<void> _showImportReport(
    List<({String fileName, PromptPresetImportResult? result})> reports,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.promptPresetImportReportTitle),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final report in reports) ...[
                  Text(
                    l10n.promptPresetImportReportFile(report.fileName),
                    style: TextStyle(fontWeight: AppFontWeights.emphasis),
                  ),
                  const SizedBox(height: 4),
                  if (report.result == null)
                    Text(
                      l10n.promptPresetImportInvalidJson,
                      style: TextStyle(color: cs.error),
                    )
                  else ...[
                    Text(
                      l10n.promptPresetImportReportSummary(
                        report.result!.importedEntries,
                        report.result!.enabledEntries,
                        report.result!.disabledEntries,
                      ),
                    ),
                    Text(
                      l10n.promptPresetImportReportSkipped(
                        report.result!.skippedMarkers,
                        report.result!.skippedEntries,
                      ),
                    ),
                    if (report.result!.skippedPluginEntries > 0)
                      Text(
                        l10n.promptPresetImportReportSkippedPlugins(
                          report.result!.skippedPluginEntries,
                        ),
                      ),
                    if (report.result!.unsupportedMacroNames.isNotEmpty)
                      Text(
                        l10n.promptPresetUnsupportedMacros(
                          report.result!.unsupportedMacroNames.join(', '),
                        ),
                        style: TextStyle(color: cs.error),
                      ),
                    if (report.result!.adjustments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          report.result!.adjustments.join('\n'),
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.72),
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 14),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.promptPresetSave),
          ),
        ],
      ),
    );
  }

  Future<String?> _showNameDialog({
    String initial = '',
    required bool editing,
  }) {
    final controller = TextEditingController(text: initial);
    final l10n = AppLocalizations.of(context)!;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          editing ? l10n.promptPresetEditName : l10n.promptPresetAddTitle,
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.of(ctx).pop(value.trim());
          },
          decoration: InputDecoration(hintText: l10n.promptPresetNameHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.promptPresetCancel),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.of(ctx).pop(controller.text.trim());
              }
            },
            child: Text(l10n.promptPresetSave),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _addPreset() async {
    final name = await _showNameDialog(editing: false);
    if (!mounted || name == null || name.trim().isEmpty) return;
    final preset = PromptPreset(
      id: const Uuid().v4(),
      name: name.trim(),
      sourceFormat: PromptPresetSourceFormat.kelivo,
      entries: const <PromptPresetEntry>[],
    );
    await context.read<PromptPresetProvider>().addPreset(preset);
    if (mounted) setState(() => _expandedPresetIds.add(preset.id));
  }

  Future<void> _renamePreset(PromptPreset preset) async {
    final name = await _showNameDialog(initial: preset.name, editing: true);
    if (!mounted || name == null || name.trim().isEmpty) return;
    await context.read<PromptPresetProvider>().renamePreset(
      preset.id,
      name.trim(),
    );
  }

  Future<void> _deletePreset(PromptPreset preset) async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.promptPresetDeleteTitle),
        content: Text(l10n.promptPresetDeleteMessage(preset.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.promptPresetCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              l10n.promptPresetDelete,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (!mounted || confirm != true) return;
    await context.read<PromptPresetProvider>().deletePreset(preset.id);
    if (mounted) setState(() => _expandedPresetIds.remove(preset.id));
  }

  Future<void> _showEntryEditor(
    PromptPreset preset, {
    PromptPresetEntry? entry,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final nameController = TextEditingController(text: entry?.name ?? '');
    final contentController = TextEditingController(text: entry?.content ?? '');
    final result = await showDialog<({String name, String content})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          entry == null
              ? l10n.promptPresetAddEntry
              : l10n.promptPresetEditEntry,
        ),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: l10n.promptPresetEntryName,
                    hintText: l10n.promptPresetEntryNameHint,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentController,
                  minLines: 4,
                  maxLines: 12,
                  decoration: InputDecoration(
                    labelText: l10n.promptPresetEntryContent,
                    hintText: l10n.promptPresetEntryContentHint,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Chip(
                        avatar: const Icon(Lucide.User, size: 15),
                        label: Text(
                          '${l10n.promptPresetRole}: ${_roleLabel(ctx, entry?.role ?? PromptPresetRole.system)}',
                        ),
                      ),
                      Chip(
                        avatar: const Icon(Lucide.ListOrdered, size: 15),
                        label: Text(
                          '${l10n.promptPresetAnchor}: ${_anchorLabel(ctx, entry?.anchor ?? PromptPresetAnchor.beforeChatHistory)}',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.promptPresetCancel),
          ),
          TextButton(
            onPressed: () {
              if (nameController.text.trim().isEmpty ||
                  contentController.text.trim().isEmpty) {
                return;
              }
              Navigator.of(ctx).pop((
                name: nameController.text.trim(),
                content: contentController.text,
              ));
            },
            child: Text(l10n.promptPresetSave),
          ),
        ],
      ),
    );
    nameController.dispose();
    contentController.dispose();
    if (!mounted || result == null) return;
    final nextEntry = entry == null
        ? PromptPresetEntry(
            id: const Uuid().v4(),
            sourceIdentifier: 'manual-${const Uuid().v4()}',
            name: result.name,
            content: result.content,
            enabled: true,
            role: PromptPresetRole.system,
            anchor: PromptPresetAnchor.beforeChatHistory,
            sourceOrder: preset.entries.length,
          )
        : entry.copyWith(name: result.name, content: result.content);
    if (entry == null) {
      await context.read<PromptPresetProvider>().addEntry(
        presetId: preset.id,
        entry: nextEntry,
      );
    } else {
      await context.read<PromptPresetProvider>().updateEntry(
        presetId: preset.id,
        entry: nextEntry,
      );
    }
  }

  String _roleLabel(BuildContext context, PromptPresetRole role) {
    final l10n = AppLocalizations.of(context)!;
    return switch (role) {
      PromptPresetRole.system => l10n.promptPresetRoleSystem,
      PromptPresetRole.user => l10n.promptPresetRoleUser,
      PromptPresetRole.assistant => l10n.promptPresetRoleAssistant,
    };
  }

  String _anchorLabel(BuildContext context, PromptPresetAnchor anchor) {
    final l10n = AppLocalizations.of(context)!;
    return switch (anchor) {
      PromptPresetAnchor.beforeChatHistory =>
        l10n.promptPresetAnchorBeforeChatHistory,
      PromptPresetAnchor.afterChatHistory =>
        l10n.promptPresetAnchorAfterChatHistory,
    };
  }

  Widget _actionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      onPressed: onTap,
    );
  }

  Widget _entryRow(
    BuildContext context,
    PromptPreset preset,
    PromptPresetEntry entry,
    int index,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final displayName = entry.name.trim().isEmpty
        ? entry.sourceIdentifier
        : entry.name.trim();
    final roleColor = switch (entry.role) {
      PromptPresetRole.system => cs.primary,
      PromptPresetRole.user => cs.secondary,
      PromptPresetRole.assistant => cs.tertiary,
    };
    final card = Container(
      key: ValueKey('prompt-preset-entry-${entry.id}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Lucide.GripVertical,
            size: 18,
            color: cs.onSurface.withValues(alpha: 0.45),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: AppFontWeights.emphasis),
                      ),
                    ),
                    Text(
                      _roleLabel(context, entry.role),
                      style: TextStyle(color: roleColor, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  entry.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.70),
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _anchorLabel(context, entry.anchor),
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.55),
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          IosSwitch(
            value: entry.enabled,
            semanticLabel: l10n.promptPresetEntryEnabled,
            onChanged: (enabled) =>
                context.read<PromptPresetProvider>().setEntryEnabled(
                  presetId: preset.id,
                  entryId: entry.id,
                  enabled: enabled,
                ),
          ),
          IconButton(
            tooltip: l10n.promptPresetEditEntry,
            icon: const Icon(Lucide.Pencil, size: 17),
            onPressed: () => _showEntryEditor(preset, entry: entry),
          ),
        ],
      ),
    );
    final platform = Theme.of(context).platform;
    final isDesktop =
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS;
    return isDesktop
        ? ReorderableDragStartListener(
            key: ValueKey('prompt-preset-entry-drag-${entry.id}'),
            index: index,
            child: card,
          )
        : ReorderableDelayedDragStartListener(
            key: ValueKey('prompt-preset-entry-drag-${entry.id}'),
            index: index,
            child: card,
          );
  }

  Widget _presetSection(
    BuildContext context,
    PromptPreset preset,
    PromptPresetProvider provider,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final expanded = _expandedPresetIds.contains(preset.id);
    final enabledCount = provider.enabledEntryCount(preset);
    final title = preset.name.trim().isEmpty
        ? l10n.promptPresetUnnamed
        : preset.name.trim();
    return Container(
      key: ValueKey('prompt-preset-${preset.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.appColors.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: expanded
                    ? l10n.promptPresetCollapse
                    : l10n.promptPresetExpand,
                icon: AnimatedRotation(
                  turns: expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Lucide.ChevronRight, size: 18),
                ),
                onPressed: () => setState(() {
                  if (expanded) {
                    _expandedPresetIds.remove(preset.id);
                  } else {
                    _expandedPresetIds.add(preset.id);
                  }
                }),
              ),
              const Icon(Lucide.Layers, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: AppFontWeights.emphasis),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${l10n.promptPresetEntryCount(preset.entries.length)} · ${l10n.promptPresetEnabledCount(enabledCount)}',
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.62),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _actionButton(
                icon: Lucide.Pencil,
                tooltip: l10n.promptPresetEditName,
                onTap: () => _renamePreset(preset),
              ),
              _actionButton(
                icon: Lucide.Trash2,
                tooltip: l10n.promptPresetDelete,
                onTap: () => _deletePreset(preset),
              ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: 4),
            if (preset.entries.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(44, 8, 8, 8),
                child: Text(
                  l10n.promptPresetNoEntries,
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
                ),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: preset.entries.length,
                onReorderItem: (oldIndex, newIndex) {
                  provider.reorderEntries(
                    presetId: preset.id,
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                  );
                },
                itemBuilder: (ctx, index) =>
                    _entryRow(ctx, preset, preset.entries[index], index),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _showEntryEditor(preset),
                icon: const Icon(Lucide.Plus, size: 17),
                label: Text(l10n.promptPresetAddEntry),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<PromptPresetProvider>();
    final presets = provider.presets;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.promptPresetSubtitle,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.68),
                      fontSize: 13,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.promptPresetImportTooltip,
                  icon: const Icon(Lucide.Import, size: 19),
                  onPressed: _importFromFiles,
                ),
                IconButton(
                  tooltip: l10n.promptPresetAddTooltip,
                  icon: const Icon(Lucide.Plus, size: 19),
                  onPressed: _addPreset,
                ),
              ],
            ),
          ),
        ),
        if (presets.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Lucide.Layers,
                    size: 60,
                    color: cs.onSurface.withValues(alpha: 0.28),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.promptPresetEmpty,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.62),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            sliver: SliverReorderableList(
              itemCount: presets.length,
              itemBuilder: (ctx, index) =>
                  _presetSection(ctx, presets[index], provider),
              onReorderItem: (oldIndex, newIndex) {
                provider.reorderPresets(oldIndex: oldIndex, newIndex: newIndex);
              },
            ),
          ),
      ],
    );
  }
}
