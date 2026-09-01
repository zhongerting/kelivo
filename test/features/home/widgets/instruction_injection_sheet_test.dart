import 'package:Kelivo/core/models/instruction_injection.dart';
import 'package:Kelivo/core/providers/instruction_injection_group_provider.dart';
import 'package:Kelivo/core/providers/instruction_injection_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/home/widgets/instruction_injection_sheet.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

final class _MemoryInstructionInjectionProvider
    extends InstructionInjectionProvider {
  _MemoryInstructionInjectionProvider([
    Iterable<InstructionInjection> initialItems = const [],
  ]) : _items = initialItems.toList(),
       super(preferences: createBusinessTestPreferences());

  final List<InstructionInjection> _items;
  final Set<String> _activeIds = <String>{};

  @override
  List<InstructionInjection> get items =>
      List<InstructionInjection>.unmodifiable(_items);

  @override
  List<String> activeIdsFor(String? assistantId) =>
      List<String>.unmodifiable(_activeIds);

  @override
  Future<void> add(InstructionInjection item) async {
    _items.add(item);
    notifyListeners();
  }

  @override
  Future<void> update(InstructionInjection item) async {
    final index = _items.indexWhere((candidate) => candidate.id == item.id);
    if (index < 0) return;
    _items[index] = item;
    notifyListeners();
  }

  @override
  Future<void> toggleActiveId(String id, {String? assistantId}) async {
    if (!_activeIds.add(id)) _activeIds.remove(id);
    notifyListeners();
  }
}

Future<void> _pumpLauncher(
  WidgetTester tester, {
  required InstructionInjectionProvider provider,
  required InstructionInjectionGroupProvider groupProvider,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<InstructionInjectionProvider>.value(
          value: provider,
        ),
        ChangeNotifierProvider<InstructionInjectionGroupProvider>.value(
          value: groupProvider,
        ),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(createBusinessTestPreferences()),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showInstructionInjectionSheet(
                context,
                assistantId: 'assistant-a',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _pumpSheetTransition(tester);
}

Future<void> _pumpSheetTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('adds an instruction from the empty chat sheet', (tester) async {
    final provider = _MemoryInstructionInjectionProvider();

    await _pumpLauncher(
      tester,
      provider: provider,
      groupProvider: InstructionInjectionGroupProvider(
        preferences: createBusinessTestPreferences(),
      ),
    );

    expect(find.text('No instruction injection cards yet'), findsOneWidget);
    await tester.tap(find.text('Add Instruction'));
    await _pumpSheetTransition(tester);

    await tester.enterText(find.byType(TextField).at(0), 'Writing style');
    await tester.enterText(
      find.byType(TextField).at(2),
      'Keep the prose terse.',
    );
    await tester.tap(find.text('Save'));
    await _pumpSheetTransition(tester);

    expect(provider.items, hasLength(1));
    expect(provider.items.single.title, 'Writing style');
    expect(find.text('Writing style'), findsOneWidget);
  });

  testWidgets('edits an instruction with the visible row action', (
    tester,
  ) async {
    final provider = _MemoryInstructionInjectionProvider([
      const InstructionInjection(
        id: 'instruction-a',
        title: 'Old title',
        prompt: 'Old prompt',
      ),
    ]);

    await _pumpLauncher(
      tester,
      provider: provider,
      groupProvider: InstructionInjectionGroupProvider(
        preferences: createBusinessTestPreferences(),
      ),
    );

    await tester.tap(find.byTooltip('Edit Instruction Injection'));
    await _pumpSheetTransition(tester);
    await tester.enterText(find.byType(TextField).at(0), 'New title');
    await tester.enterText(find.byType(TextField).at(2), 'New prompt');
    await tester.tap(find.text('Save'));
    await _pumpSheetTransition(tester);

    expect(provider.items.single.title, 'New title');
    expect(provider.items.single.prompt, 'New prompt');
    expect(find.text('New title'), findsOneWidget);
  });
}
