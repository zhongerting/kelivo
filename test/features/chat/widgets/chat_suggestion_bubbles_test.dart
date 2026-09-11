import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/chat/widgets/chat_suggestion_bubbles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final count in [6, 7, 8]) {
    testWidgets('renders and taps up to seven of $count options on mobile', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final tapped = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatSuggestionBubbles(
              suggestions: List.generate(count, (i) => '行动 ${i + 1}'),
              onTap: tapped.add,
            ),
          ),
        ),
      );
      final visibleCount = count > 7 ? 7 : count;
      for (var i = 1; i <= visibleCount; i++) {
        expect(find.text('行动 $i'), findsOneWidget);
        await tester.tap(find.text('行动 $i'));
        await tester.pumpAndSettle();
      }
      expect(find.text('行动 8'), findsNothing);
      expect(tapped, List.generate(visibleCount, (i) => '行动 ${i + 1}'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('renders suggestion bubbles and reports taps', (tester) async {
    final tapped = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatSuggestionBubbles(
            suggestions: const ['继续', '举例', '总结'],
            onTap: tapped.add,
          ),
        ),
      ),
    );

    expect(find.text('继续'), findsOneWidget);
    expect(find.text('举例'), findsOneWidget);
    expect(find.text('总结'), findsOneWidget);

    await tester.tap(find.text('举例'));
    await tester.pump();

    expect(tapped, ['举例']);
  });
}
