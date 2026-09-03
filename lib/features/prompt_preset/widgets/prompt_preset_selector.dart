import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/prompt_preset.dart';
import '../../../core/providers/prompt_preset_provider.dart';
import '../../../desktop/widgets/desktop_select_dropdown.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../theme/app_font_weights.dart';
import '../pages/prompt_preset_page.dart';

class PromptPresetSelector extends StatefulWidget {
  const PromptPresetSelector({super.key, required this.assistantId});

  final String assistantId;

  @override
  State<PromptPresetSelector> createState() => _PromptPresetSelectorState();
}

class _PromptPresetSelectorState extends State<PromptPresetSelector> {
  static const _noneValue = '__kelivo_no_prompt_preset__';

  bool get _isDesktop {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PromptPresetProvider?>()?.initialize();
    });
  }

  Future<void> _setValue(String value) async {
    await context.read<PromptPresetProvider?>()?.setSelectedPresetId(
      widget.assistantId,
      value == _noneValue ? null : value,
    );
  }

  Future<void> _openManagement() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const PromptPresetPage()));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<PromptPresetProvider?>();
    final selected = provider?.selectedPresetFor(widget.assistantId);
    final value = selected?.id ?? _noneValue;
    final options = <DesktopSelectOption<String>>[
      DesktopSelectOption(value: _noneValue, label: l10n.promptPresetNoPreset),
      for (final preset in provider?.presets ?? const <PromptPreset>[])
        DesktopSelectOption(
          value: preset.id,
          label: preset.name.trim().isEmpty
              ? l10n.promptPresetUnnamed
              : preset.name.trim(),
          subtitle: l10n.promptPresetSelectionSummary(
            provider?.enabledEntryCount(preset) ??
                preset.entries.where((entry) => entry.enabled).length,
          ),
        ),
    ];
    return SectionCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 36,
                child: Icon(Lucide.Layers, size: 20, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.promptPresetSelectionTitle,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.emphasis,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      selected == null
                          ? l10n.promptPresetSelectionNoneSubtitle
                          : l10n.promptPresetSelectionSummary(
                              provider?.enabledEntryCount(selected) ??
                                  selected.entries
                                      .where((entry) => entry.enabled)
                                      .length,
                            ),
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.62),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_isDesktop)
                      DesktopSelectDropdown<String>(
                        value: value,
                        options: options,
                        minWidth: 250,
                        onSelected: _setValue,
                      )
                    else
                      DropdownButtonFormField<String>(
                        initialValue: value,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: l10n.promptPresetSelectionTitle,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        items: [
                          for (final option in options)
                            DropdownMenuItem<String>(
                              value: option.value,
                              child: Text(
                                option.label,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (next) {
                          if (next != null) _setValue(next);
                        },
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _openManagement,
                        icon: const Icon(Lucide.Settings2, size: 16),
                        label: Text(l10n.promptPresetSelectionManage),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
