import '../../../core/models/prompt_preset.dart';

class PromptPresetMacroContext {
  const PromptPresetMacroContext({
    required this.userName,
    required this.charName,
    required this.lastUserMessage,
  });

  final String userName;
  final String charName;
  final String lastUserMessage;
}

class PromptPresetRenderedEntry {
  const PromptPresetRenderedEntry({required this.entry, required this.content});

  final PromptPresetEntry entry;
  final String content;
}

class PromptPresetMacroService {
  PromptPresetMacroService._();

  static final RegExp _macroPattern = RegExp(r'\{\{([\s\S]*?)\}\}');
  static const int _maxVariableExpansionDepth = 8;

  static List<PromptPresetRenderedEntry> renderEnabledEntries(
    Iterable<PromptPresetEntry> entries, {
    required PromptPresetMacroContext context,
  }) {
    final ordered = entries.toList(growable: false).asMap().entries.toList()
      ..sort((left, right) {
        final byOrder = left.value.sourceOrder.compareTo(
          right.value.sourceOrder,
        );
        return byOrder != 0 ? byOrder : left.key.compareTo(right.key);
      });
    final variables = <String, String>{};
    final rendered = <PromptPresetRenderedEntry>[];
    for (final item in ordered) {
      final entry = item.value;
      if (!entry.enabled) continue;
      final content = _renderEntry(
        entry.content,
        context: context,
        variables: variables,
      );
      if (content.trim().isEmpty) continue;
      rendered.add(PromptPresetRenderedEntry(entry: entry, content: content));
    }
    return rendered;
  }

  static String render(
    String content, {
    required PromptPresetMacroContext context,
    Map<String, String>? variables,
  }) {
    return _renderEntry(
      content,
      context: context,
      variables: variables ?? <String, String>{},
    );
  }

  static List<String> findUnsupportedMacroNames(String content) {
    final names = <String>[];
    final seen = <String>{};
    for (final match in _macroPattern.allMatches(content)) {
      final raw = match.group(1) ?? '';
      final name = _macroName(raw);
      if (name.isEmpty || _isSupportedName(name)) continue;
      if (seen.add(name)) names.add(name);
    }
    return names;
  }

  static String _renderEntry(
    String content, {
    required PromptPresetMacroContext context,
    required Map<String, String> variables,
  }) {
    var trimRequested = false;
    final contextual = content.replaceAllMapped(_macroPattern, (match) {
      final raw = match.group(1) ?? '';
      final trimmed = raw.trim();
      if (trimmed.startsWith('//')) return '';
      final name = _macroName(raw);
      switch (name) {
        case 'user':
          return context.userName;
        case 'char':
          return context.charName;
        case 'lastusermessage':
          return context.lastUserMessage;
        case 'trim':
          trimRequested = true;
          return '';
        default:
          return match.group(0) ?? '';
      }
    });

    final withVariables = contextual.replaceAllMapped(_macroPattern, (match) {
      final raw = match.group(1) ?? '';
      final name = _macroName(raw);
      if (name == 'setvar') {
        final parsed = _parseDoubleColonMacro(raw);
        if (parsed == null || parsed.name.isEmpty) {
          return match.group(0) ?? '';
        }
        variables[parsed.name.toLowerCase()] = _expandGetVars(
          parsed.value,
          variables,
        );
        return '';
      }
      if (name == 'getvar') {
        final parsed = _parseSingleValueMacro(raw);
        if (parsed == null || parsed.trim().isEmpty) {
          return match.group(0) ?? '';
        }
        return _resolveVariable(parsed.trim(), variables);
      }
      return match.group(0) ?? '';
    });
    return trimRequested ? withVariables.trim() : withVariables;
  }

  static String _expandGetVars(
    String value,
    Map<String, String> variables, {
    Set<String> stack = const <String>{},
    int depth = 0,
  }) {
    if (depth >= _maxVariableExpansionDepth) return value;
    return value.replaceAllMapped(_macroPattern, (match) {
      final raw = match.group(1) ?? '';
      if (_macroName(raw) != 'getvar') return match.group(0) ?? '';
      final name = _parseSingleValueMacro(raw)?.trim() ?? '';
      if (name.isEmpty) return match.group(0) ?? '';
      final normalized = name.toLowerCase();
      if (stack.contains(normalized)) return match.group(0) ?? '';
      final nextStack = {...stack, normalized};
      return _expandGetVars(
        variables[normalized] ?? '',
        variables,
        stack: nextStack,
        depth: depth + 1,
      );
    });
  }

  static String _resolveVariable(String name, Map<String, String> variables) {
    return _expandGetVars(
      variables[name.toLowerCase()] ?? '',
      variables,
      stack: {name.toLowerCase()},
    );
  }

  static String _macroName(String raw) {
    final body = raw.trim();
    if (body.startsWith('//')) return '//';
    final separator = body.indexOf('::');
    final token = separator == -1
        ? body.split(RegExp(r'\s+')).first
        : body.substring(0, separator);
    return token.trim().toLowerCase();
  }

  static bool _isSupportedName(String name) =>
      name == 'user' ||
      name == 'char' ||
      name == 'lastusermessage' ||
      name == 'setvar' ||
      name == 'getvar' ||
      name == 'trim' ||
      name == '//';

  static ({String name, String value})? _parseDoubleColonMacro(String raw) {
    final first = raw.indexOf('::');
    if (first == -1) return null;
    final second = raw.indexOf('::', first + 2);
    if (second == -1) return null;
    return (
      name: raw.substring(first + 2, second).trim(),
      value: raw.substring(second + 2),
    );
  }

  static String? _parseSingleValueMacro(String raw) {
    final separator = raw.indexOf('::');
    if (separator == -1) return null;
    return raw.substring(separator + 2).trim();
  }
}
