/// Safe rendering for the two character-card macros supported by Kelivo.
///
/// This intentionally does not share the prompt-preset macro renderer: a
/// character card is only allowed to substitute the current names. Unknown
/// macros remain in the text and no source string is ever evaluated.
class CharacterCardMacroService {
  CharacterCardMacroService._();

  static final RegExp _macroPattern = RegExp(r'\{\{([\s\S]*?)\}\}');

  static String render(
    String content, {
    required String charName,
    required String userName,
  }) {
    return content.replaceAllMapped(_macroPattern, (match) {
      final body = (match.group(1) ?? '').trim().toLowerCase();
      if (body == 'char') return charName;
      if (body == 'user') return userName;
      return match.group(0) ?? '';
    });
  }
}
