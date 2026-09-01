import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/quick_phrase.dart';
import 'package:Kelivo/features/quick_phrase/widgets/quick_phrase_menu.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phrase row sends while append button only appends', (
    tester,
  ) async {
    const phrase = QuickPhrase(
      id: 'continue',
      title: 'Continue',
      content: 'Continue the story',
    );
    final selections = <QuickPhraseSelection>[];

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: QuickPhraseMenu(
            phrases: const [phrase],
            onSelect: selections.add,
            anchorPosition: const Offset(16, 72),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Append'));
    await tester.pump();

    expect(selections, hasLength(1));
    expect(selections.single.phrase, same(phrase));
    expect(selections.single.action, QuickPhraseAction.append);

    selections.clear();
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(selections, hasLength(1));
    expect(selections.single.phrase, same(phrase));
    expect(selections.single.action, QuickPhraseAction.send);
  });
}
