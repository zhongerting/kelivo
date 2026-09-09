import 'dart:async';

import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';

/// Displays the structured reply choices belonging to the last assistant
/// reply. The panel owns presentation only; sending and input insertion stay
/// with the home controller.
class ReplyOptionsPanel extends StatelessWidget {
  const ReplyOptionsPanel({
    super.key,
    required this.options,
    required this.expanded,
    required this.onExpandedChanged,
    required this.onSend,
    required this.onAppend,
    this.enabled = true,
  });

  static const double _headerHeight = 48;
  static const double _rowMinHeight = 52;
  static const double _maxListHeight = _rowMinHeight * 6;

  final List<String> options;
  final bool expanded;
  final bool enabled;
  final ValueChanged<bool> onExpandedChanged;
  final Future<void> Function(String option) onSend;
  final ValueChanged<String> onAppend;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final panelColor = cs.surfaceContainerLow.withValues(alpha: 0.94);
    final borderColor = cs.outline.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.18 : 0.14,
    );

    return Semantics(
      container: true,
      label: l10n.replyOptionsTitle,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: panelColor,
          border: Border(top: BorderSide(color: borderColor)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: _headerHeight,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: enabled ? () => onExpandedChanged(!expanded) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Icon(Lucide.ListChecks, size: 18, color: cs.primary),
                        const SizedBox(width: 8),
                        Text(
                          l10n.replyOptionsTitle,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 14,
                            fontWeight: AppFontWeights.emphasis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.replyOptionsCount(options.length),
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.58),
                            fontSize: 12,
                            fontWeight: AppFontWeights.medium,
                          ),
                        ),
                        const Spacer(),
                        Semantics(
                          button: true,
                          label: expanded
                              ? l10n.replyOptionsCollapse
                              : l10n.replyOptionsExpand,
                          child: Icon(
                            expanded ? Lucide.ChevronDown : Lucide.ChevronUp,
                            size: 20,
                            color: cs.onSurface.withValues(alpha: 0.62),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (expanded)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: _maxListHeight),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  itemCount: options.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    indent: 8,
                    endIndent: 8,
                    color: borderColor,
                  ),
                  itemBuilder: (context, index) {
                    final option = options[index];
                    return _ReplyOptionRow(
                      option: option,
                      enabled: enabled,
                      minHeight: _rowMinHeight,
                      appendLabel: l10n.replyOptionsAppend,
                      appendTooltip: l10n.replyOptionsAppendTooltip,
                      sendTooltip: l10n.replyOptionsSendTooltip,
                      onSend: () => unawaited(onSend(option)),
                      onAppend: () => onAppend(option),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReplyOptionRow extends StatelessWidget {
  const _ReplyOptionRow({
    required this.option,
    required this.enabled,
    required this.minHeight,
    required this.appendLabel,
    required this.appendTooltip,
    required this.sendTooltip,
    required this.onSend,
    required this.onAppend,
  });

  final String option;
  final bool enabled;
  final double minHeight;
  final String appendLabel;
  final String appendTooltip;
  final String sendTooltip;
  final VoidCallback onSend;
  final VoidCallback onAppend;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bodyColor = cs.onSurface;
    final secondaryColor = cs.onSurface.withValues(alpha: 0.58);

    return SizedBox(
      key: ValueKey<String>('reply-option:$option'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: sendTooltip,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: enabled ? onSend : null,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: minHeight),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          option,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: enabled
                                ? bodyColor
                                : bodyColor.withValues(alpha: 0.42),
                            fontSize: 14,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Semantics(
            button: true,
            label: appendTooltip,
            child: Tooltip(
              message: appendTooltip,
              child: TextButton.icon(
                onPressed: enabled ? onAppend : null,
                icon: const Icon(Lucide.Plus, size: 16),
                label: Text(appendLabel),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: enabled ? cs.primary : secondaryColor,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
