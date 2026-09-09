import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/home/widgets/reply_options_panel.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

Widget _app(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty options occupy no height', (tester) async {
    await tester.pumpWidget(
      _app(
        const ReplyOptionsPanel(
          options: <String>[],
          expanded: true,
          onExpandedChanged: _noopExpanded,
          onSend: _noopSend,
          onAppend: _noopAppend,
        ),
      ),
    );

    expect(tester.getSize(find.byType(ReplyOptionsPanel)), Size.zero);
  });

  testWidgets('row send and append actions stay independent', (tester) async {
    final sent = <String>[];
    final appended = <String>[];
    var expanded = true;

    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => ReplyOptionsPanel(
            options: const <String>['调查房间', '询问对方'],
            expanded: expanded,
            onExpandedChanged: (value) => setState(() => expanded = value),
            onSend: (option) async => sent.add(option),
            onAppend: appended.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Append').first);
    await tester.pump();
    expect(appended, ['调查房间']);
    expect(sent, isEmpty);

    await tester.tap(find.text('询问对方'));
    await tester.pump();
    expect(sent, ['询问对方']);
    expect(appended, ['调查房间']);
  });

  testWidgets('collapse hides rows and expanded list is capped at six rows', (
    tester,
  ) async {
    final options = List<String>.generate(8, (index) => 'Option $index');
    var expanded = true;

    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => ReplyOptionsPanel(
            options: options,
            expanded: expanded,
            onExpandedChanged: (value) => setState(() => expanded = value),
            onSend: _noopSend,
            onAppend: _noopAppend,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final listSize = tester.getSize(find.byType(ListView));
    expect(listSize.height, lessThanOrEqualTo(52 * 6));
    expect(find.text('Option 0'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -260));
    await tester.pump();
    expect(find.text('Option 7'), findsOneWidget);

    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(find.byType(ListView), findsNothing);
    expect(find.text('Option 0'), findsNothing);
  });
}

void _noopExpanded(bool _) {}

Future<void> _noopSend(String _) async {}

void _noopAppend(String _) {}
