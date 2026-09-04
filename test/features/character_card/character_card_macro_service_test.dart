import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/character_card/services/character_card_macro_service.dart';

void main() {
  test('expands only the supported character-card macros', () {
    final rendered = CharacterCardMacroService.render(
      '{{char}} greets {{ user }}. {{unknown::value}} {{setvar::x::no}}',
      charName: 'Mira',
      userName: 'Alex',
    );

    expect(rendered, 'Mira greets Alex. {{unknown::value}} {{setvar::x::no}}');
  });

  test('keeps macro-looking text and code inert', () {
    final rendered = CharacterCardMacroService.render(
      '{{javascript::alert(1)}} {{char.toString()}}',
      charName: 'Mira',
      userName: 'Alex',
    );

    expect(rendered, '{{javascript::alert(1)}} {{char.toString()}}');
  });
}
