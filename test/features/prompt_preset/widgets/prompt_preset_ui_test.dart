import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/models/prompt_preset.dart';
import 'package:Kelivo/core/providers/prompt_preset_provider.dart';
import 'package:Kelivo/features/prompt_preset/pages/prompt_preset_page.dart';
import 'package:Kelivo/features/prompt_preset/widgets/prompt_preset_selector.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/ios_switch.dart';

import '../../../support/business_test_harness.dart';

PromptPreset _preset() => const PromptPreset(
  id: 'preset-ui',
  name: 'UI preset',
  sourceFormat: PromptPresetSourceFormat.sillyTavern,
  entries: [
    PromptPresetEntry(
      id: 'entry-ui',
      sourceIdentifier: 'entry-ui',
      name: 'UI entry',
      content: 'Keep the answer concise.',
      enabled: true,
      role: PromptPresetRole.system,
      anchor: PromptPresetAnchor.beforeChatHistory,
      sourceOrder: 0,
    ),
  ],
);

Widget _app({required Widget home, required PromptPresetProvider provider}) {
  return ChangeNotifierProvider<PromptPresetProvider>.value(
    value: provider,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

void main() {
  testWidgets('management page toggles individual prompt entries', (
    tester,
  ) async {
    final harness = await createBusinessTestHarness();
    final provider = PromptPresetProvider(preferences: harness.preferences);
    await provider.initialize();
    await provider.addPreset(_preset());

    await tester.pumpWidget(
      _app(home: const PromptPresetPage(), provider: provider),
    );
    await tester.pumpAndSettle();

    expect(find.text('UI preset'), findsOneWidget);
    await tester.tap(find.byTooltip('Expand preset'));
    await tester.pumpAndSettle();
    expect(find.text('UI entry'), findsOneWidget);
    final toggle = find.byType(IosSwitch);
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(provider.presets.single.entries.single.enabled, isFalse);
  });

  testWidgets('assistant selector supports one preset or no preset', (
    tester,
  ) async {
    final harness = await createBusinessTestHarness();
    final provider = PromptPresetProvider(preferences: harness.preferences);
    await provider.initialize();
    await provider.addPreset(_preset());
    await provider.setSelectedPresetId('assistant-ui', 'preset-ui');

    await tester.pumpWidget(
      _app(
        home: const Scaffold(
          body: PromptPresetSelector(assistantId: 'assistant-ui'),
        ),
        provider: provider,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('UI preset'), findsOneWidget);
    final dropdown = find.byType(DropdownButtonFormField<String>);
    expect(dropdown, findsOneWidget);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Do not use a prompt preset').last);
    await tester.pumpAndSettle();

    expect(provider.selectedPresetFor('assistant-ui'), isNull);
  });
}
