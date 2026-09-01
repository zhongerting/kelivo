import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../core/models/instruction_injection.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/providers/instruction_injection_group_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../core/services/haptics.dart';
import '../../../features/instruction_injection/pages/instruction_injection_page.dart';
import '../../../theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';
import '../../../shared/widgets/section_card.dart';

/// Bottom sheet for displaying instruction injection items on mobile/tablet.
///
/// This widget shows a list of instruction injection prompts that can be
/// toggled on/off for the current assistant.
class InstructionInjectionSheet extends StatelessWidget {
  const InstructionInjectionSheet({super.key, required this.assistantId});

  final String? assistantId;

  Future<void> _showEditor(
    BuildContext context, {
    InstructionInjection? item,
  }) async {
    final result = await showModalBottomSheet<Map<String, String>?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.overlaySurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => InstructionInjectionEditSheet(item: item),
    );
    if (result == null || !context.mounted) return;

    final title = result['title']?.trim() ?? '';
    final prompt = result['prompt']?.trim() ?? '';
    final group = result['group']?.trim() ?? '';
    if (title.isEmpty || prompt.isEmpty) return;

    final provider = context.read<InstructionInjectionProvider>();
    if (item == null) {
      await provider.add(
        InstructionInjection(
          id: const Uuid().v4(),
          title: title,
          prompt: prompt,
          group: group,
        ),
      );
    } else {
      await provider.update(
        item.copyWith(title: title, prompt: prompt, group: group),
      );
    }
  }

  void _openManager(BuildContext context) {
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    Navigator.of(context).maybePop();
    Future.microtask(() {
      rootNavigator.push(
        MaterialPageRoute(builder: (_) => const InstructionInjectionPage()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      top: false,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.85,
        minChildSize: 0.45,
        builder: (ctx, controller) {
          final cs = Theme.of(ctx).colorScheme;
          final provider = ctx.watch<InstructionInjectionProvider>();
          final groupUi = ctx.watch<InstructionInjectionGroupProvider>();

          final items = provider.items;
          final activeIds = provider.activeIdsFor(assistantId).toSet();

          final Map<String, List<InstructionInjection>> grouped =
              <String, List<InstructionInjection>>{};
          for (final item in items) {
            final g = item.group.trim();
            (grouped[g] ??= <InstructionInjection>[]).add(item);
          }
          final groupNames = grouped.keys.toList()
            ..sort((a, b) {
              final aa = a.trim();
              final bb = b.trim();
              if (aa.isEmpty && bb.isNotEmpty) return -1;
              if (aa.isNotEmpty && bb.isEmpty) return 1;
              return aa.toLowerCase().compareTo(bb.toLowerCase());
            });

          return Column(
            children: [
              _SheetTopBar(
                title: l10n.instructionInjectionTitle,
                onBack: () => Navigator.of(ctx).maybePop(),
                onAdd: () => _showEditor(ctx),
                onManage: () => _openManager(ctx),
              ),
              Expanded(
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    if (items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 32, bottom: 24),
                        child: Column(
                          children: [
                            Text(
                              l10n.instructionInjectionEmptyMessage,
                              style: TextStyle(
                                color: cs.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                            const SizedBox(height: 16),
                            _EmptyAddButton(
                              label: l10n.instructionInjectionAddTooltip,
                              onTap: () => _showEditor(ctx),
                            ),
                          ],
                        ),
                      )
                    else
                      for (final groupName in groupNames) ...[
                        _GroupHeader(
                          title: groupName.trim().isEmpty
                              ? l10n.instructionInjectionUngroupedGroup
                              : groupName.trim(),
                          collapsed: groupUi.isCollapsed(groupName),
                          onToggle: () => ctx
                              .read<InstructionInjectionGroupProvider>()
                              .toggleCollapsed(groupName),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeInOutCubic,
                          alignment: Alignment.topCenter,
                          child: groupUi.isCollapsed(groupName)
                              ? const SizedBox.shrink()
                              : Column(
                                  children: [
                                    for (
                                      int i = 0;
                                      i < (grouped[groupName]?.length ?? 0);
                                      i++
                                    )
                                      Padding(
                                        padding: EdgeInsets.only(
                                          bottom:
                                              i ==
                                                  (grouped[groupName]!.length -
                                                      1)
                                              ? 12
                                              : 8,
                                        ),
                                        child: _InstructionInjectionRow(
                                          label:
                                              (grouped[groupName]![i].title)
                                                  .trim()
                                                  .isEmpty
                                              ? l10n.instructionInjectionDefaultTitle
                                              : grouped[groupName]![i].title,
                                          selected: activeIds.contains(
                                            grouped[groupName]![i].id,
                                          ),
                                          onTap: () async {
                                            Haptics.light();
                                            final prov = ctx
                                                .read<
                                                  InstructionInjectionProvider
                                                >();
                                            await prov.toggleActiveId(
                                              grouped[groupName]![i].id,
                                              assistantId: assistantId,
                                            );
                                          },
                                          onLongPress: () async {
                                            Haptics.medium();
                                            final item = grouped[groupName]![i];
                                            await _showEditor(ctx, item: item);
                                          },
                                          onEdit: () => _showEditor(
                                            ctx,
                                            item: grouped[groupName]![i],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                      ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SheetTopBar extends StatelessWidget {
  const _SheetTopBar({
    required this.title,
    required this.onBack,
    required this.onAdd,
    required this.onManage,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback onAdd;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: _NavIconButton(icon: Lucide.ArrowLeft, onTap: onBack),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 88),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: AppFontWeights.emphasis,
                  color: cs.onSurface,
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: AppLocalizations.of(
                      context,
                    )!.instructionInjectionAddTooltip,
                    child: _NavIconButton(icon: Lucide.Plus, onTap: onAdd),
                  ),
                  Tooltip(
                    message: AppLocalizations.of(
                      context,
                    )!.settingsPageInstructionInjection,
                    child: _NavIconButton(
                      icon: Lucide.Settings2,
                      onTap: onManage,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavIconButton extends StatelessWidget {
  const _NavIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 40,
      height: 40,
      child: IosCardPress(
        borderRadius: BorderRadius.circular(12),
        baseColor: Colors.transparent,
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.zero,
        onTap: () {
          Haptics.light();
          onTap();
        },
        child: Center(child: Icon(icon, size: 20, color: cs.onSurface)),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.collapsed,
    required this.onToggle,
  });

  final String title;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textBase = cs.onSurface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: Center(
                child: AnimatedRotation(
                  turns: collapsed ? 0.0 : 0.25, // right -> down
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: Icon(
                    Lucide.ChevronRight,
                    size: 16,
                    color: textBase.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: AppFontWeights.emphasis,
                  color: textBase,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InstructionInjectionRow extends StatelessWidget {
  const _InstructionInjectionRow({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    this.onLongPress,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final onColor = selected ? cs.primary : cs.onSurface;
    final radius = BorderRadius.circular(14);
    return SizedBox(
      height: 48,
      child: IosCardPress(
        borderRadius: radius,
        baseColor: sheetTileColor(context),
        duration: const Duration(milliseconds: 260),
        onTap: onTap,
        onLongPress: onLongPress,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(Lucide.Layers, size: 20, color: onColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.medium,
                  color: onColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (selected)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Lucide.Check, size: 18, color: cs.primary),
              ),
            Tooltip(
              message: AppLocalizations.of(
                context,
              )!.instructionInjectionEditTitle,
              child: _NavIconButton(icon: Lucide.Pencil, onTap: onEdit),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyAddButton extends StatelessWidget {
  const _EmptyAddButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      borderRadius: BorderRadius.circular(12),
      baseColor: cs.primary.withValues(alpha: 0.12),
      duration: const Duration(milliseconds: 200),
      onTap: () {
        Haptics.light();
        onTap();
      },
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Lucide.Plus, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: cs.primary,
              fontWeight: AppFontWeights.emphasis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the instruction injection bottom sheet.
///
/// This is a convenience function to show the sheet with proper styling.
Future<void> showInstructionInjectionSheet(
  BuildContext context, {
  required String? assistantId,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.overlaySurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) {
      return InstructionInjectionSheet(assistantId: assistantId);
    },
  );
}
