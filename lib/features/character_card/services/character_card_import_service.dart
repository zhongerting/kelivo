import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../world_book/services/world_book_import_service.dart';
import '../models/character_card_import_result.dart';

class CharacterCardImportException implements Exception {
  const CharacterCardImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Parses the deliberately small, non-executable subset of a SillyTavern
/// character card. Nothing from the source is evaluated or retained as a
/// runtime rule unless it is copied into one of the explicit typed drafts.
class CharacterCardImportService {
  const CharacterCardImportService._();

  static const int maxJsonBytes = 8 * 1024 * 1024;
  static const int maxPngBytes = 32 * 1024 * 1024;
  // Base64 expands an 8 MiB JSON payload to just over 10.6 MiB. Leave room
  // for the metadata keyword and iTXt framing while keeping the PNG total
  // size limit independent.
  static const int maxPngMetadataBytes = 12 * 1024 * 1024;
  static const int maxPngChunks = 10000;
  static const int maxWorldBookEntries =
      WorldBookImportService.maxCharacterCardEntries;
  static const int maxWorldBookEntryContentBytes =
      WorldBookImportService.maxCharacterCardEntryContentBytes;

  static CharacterCardImportResult parseJsonString(
    String raw, {
    String fallbackName = '',
    String sourceFileName = '',
  }) {
    if (utf8.encode(raw).length > maxJsonBytes) {
      throw const CharacterCardImportException(
        'Character card JSON exceeds the safety limit.',
      );
    }
    late final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const CharacterCardImportException(
        'Character card JSON is invalid.',
      );
    }
    if (decoded is! Map) {
      throw const CharacterCardImportException(
        'Character card JSON must contain an object at the root.',
      );
    }
    return _parseRoot(
      _asMap(decoded)!,
      sourceFormat: _jsonFormat(_asMap(decoded)!),
      fallbackName: fallbackName,
      sourceFileName: sourceFileName,
    );
  }

  static CharacterCardImportResult parseJsonBytes(
    Uint8List bytes, {
    String fallbackName = '',
    String sourceFileName = '',
  }) {
    if (bytes.length > maxJsonBytes) {
      throw const CharacterCardImportException(
        'Character card JSON exceeds the safety limit.',
      );
    }
    late final String raw;
    try {
      raw = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const CharacterCardImportException(
        'Character card JSON is not valid UTF-8.',
      );
    }
    return parseJsonString(
      raw,
      fallbackName: fallbackName,
      sourceFileName: sourceFileName,
    );
  }

  static CharacterCardImportResult parsePngBytes(
    Uint8List bytes, {
    String fallbackName = '',
    String sourceFileName = '',
  }) {
    if (bytes.length > maxPngBytes) {
      throw const CharacterCardImportException(
        'Character card PNG exceeds the safety limit.',
      );
    }
    if (bytes.length < 8 || !_hasPngSignature(bytes)) {
      throw const CharacterCardImportException('The file is not a PNG image.');
    }

    final text = <String, String>{};
    var offset = 8;
    var chunkCount = 0;
    var metadataBytes = 0;
    var sawIend = false;
    while (offset < bytes.length) {
      chunkCount++;
      if (chunkCount > maxPngChunks) {
        throw const CharacterCardImportException(
          'PNG contains too many chunks.',
        );
      }
      if (bytes.length - offset < 12) {
        throw const CharacterCardImportException(
          'PNG chunk header is truncated.',
        );
      }
      final length = _uint32(bytes, offset);
      final chunkEnd = offset + 12 + length;
      if (chunkEnd < offset || chunkEnd > bytes.length) {
        throw const CharacterCardImportException('PNG chunk is truncated.');
      }
      final type = _decodeAsciiRange(bytes, offset + 4, 4);
      if (type == null) {
        throw const CharacterCardImportException(
          'PNG chunk type is not valid ASCII.',
        );
      }
      final dataStart = offset + 8;
      if (type == 'tEXt' || type == 'iTXt') {
        metadataBytes += length;
        if (metadataBytes > maxPngMetadataBytes) {
          throw const CharacterCardImportException(
            'PNG character metadata exceeds the safety limit.',
          );
        }
        final chunk = Uint8List.fromList(
          bytes.sublist(dataStart, dataStart + length),
        );
        final decoded = type == 'tEXt'
            ? _decodeTextChunk(chunk)
            : _decodeInternationalTextChunk(chunk);
        if (decoded != null) {
          final key = decoded.$1;
          if (key == 'ccv3' || key == 'chara') {
            if (text.containsKey(key)) {
              throw const CharacterCardImportException(
                'PNG contains duplicate character metadata.',
              );
            }
            text[key] = decoded.$2;
          }
        }
      }
      offset = chunkEnd;
      if (type == 'IEND') {
        sawIend = true;
        break;
      }
    }
    if (!sawIend) {
      throw const CharacterCardImportException(
        'PNG is missing its IEND chunk.',
      );
    }

    final encoded = text['ccv3'] ?? text['chara'];
    if (encoded == null || encoded.trim().isEmpty) {
      throw const CharacterCardImportException(
        'PNG does not contain ccv3 or chara character metadata.',
      );
    }
    final jsonBytes = _decodeBase64(encoded);
    final parsed = parseJsonBytes(
      jsonBytes,
      fallbackName: fallbackName,
      sourceFileName: sourceFileName,
    );
    return parsed.copyWith(
      sourceFormat: CharacterCardSourceFormat.png,
      sourceFileName: sourceFileName,
      assistantDraft: CharacterCardAssistantDraft(
        name: parsed.assistantDraft.name,
        characterPrompt: parsed.assistantDraft.characterPrompt,
        firstMessage: parsed.assistantDraft.firstMessage,
        avatarBytes: Uint8List.fromList(bytes),
        avatarMimeType: 'image/png',
      ),
    );
  }

  static Future<CharacterCardImportResult> parseFile(
    File file, {
    String? sourceFileName,
  }) async {
    final length = await file.length();
    if (length < 1) {
      throw const CharacterCardImportException('Character card file is empty.');
    }
    final name = sourceFileName ?? p.basename(file.path);
    final lower = name.toLowerCase();
    final limit = lower.endsWith('.png') ? maxPngBytes : maxJsonBytes;
    if (length > limit) {
      throw const CharacterCardImportException(
        'Character card file exceeds the safety limit.',
      );
    }
    final bytes = await file.readAsBytes();
    if (_hasPngSignature(bytes)) {
      return parsePngBytes(
        bytes,
        fallbackName: _fallbackName(name),
        sourceFileName: name,
      );
    }
    return parseJsonBytes(
      bytes,
      fallbackName: _fallbackName(name),
      sourceFileName: name,
    );
  }

  static CharacterCardImportResult _parseRoot(
    Map<String, dynamic> root, {
    required CharacterCardSourceFormat sourceFormat,
    required String fallbackName,
    required String sourceFileName,
  }) {
    final data = _asMap(root['data']);
    final payload = data ?? root;
    final warnings = <String>[];
    final imported = <String>[];
    final ignored = <String>[];
    final ignoredCounts = <String, int>{};

    final name = _string(payload['name']).trim().isNotEmpty
        ? _string(payload['name'])
        : (_string(root['name']).trim().isNotEmpty
              ? _string(root['name'])
              : fallbackName);
    if (name.trim().isNotEmpty) imported.add('name');

    final fields = <({String key, String tag, String close})>[
      (
        key: 'description',
        tag: '<character_description>',
        close: '</character_description>',
      ),
      (
        key: 'personality',
        tag: '<character_personality>',
        close: '</character_personality>',
      ),
      (
        key: 'scenario',
        tag: '<character_scenario>',
        close: '</character_scenario>',
      ),
    ];
    final promptParts = <String>[];
    for (final field in fields) {
      final value = _string(payload[field.key]);
      if (value.trim().isEmpty) continue;
      promptParts.add('${field.tag}\n$value\n${field.close}');
      imported.add(field.key);
    }
    final firstMessage = _string(payload['first_mes']);
    if (firstMessage.trim().isNotEmpty) imported.add('first_mes');

    final embeddedBook = _parseWorldBook(
      _asMap(payload['character_book']) ?? _asMap(root['character_book']),
      warnings: warnings,
      imported: imported,
    );

    void ignoredIfPresent(String label, dynamic value) {
      if (value == null) return;
      ignored.add(label);
      ignoredCounts[label] = (ignoredCounts[label] ?? 0) + 1;
    }

    final containers = <Map<String, dynamic>>[root, if (data != null) data];
    for (final container in containers) {
      ignoredIfPresent('system_prompt', container['system_prompt']);
      ignoredIfPresent(
        'post_history_instructions',
        container['post_history_instructions'],
      );
      ignoredIfPresent('mes_example', container['mes_example']);
      ignoredIfPresent('alternate_greetings', container['alternate_greetings']);
      final extensions = _asMap(container['extensions']);
      if (extensions == null) continue;
      ignoredIfPresent('extensions.depth_prompt', extensions['depth_prompt']);
      ignoredIfPresent('extensions.regex_scripts', extensions['regex_scripts']);
      for (final key in const [
        'tavern_helper',
        'js_slash_runner',
        'javascript',
        'html',
        'iframe',
        'slash_commands',
        'regexes',
      ]) {
        ignoredIfPresent('extensions.$key', extensions[key]);
      }
      final known = {
        'depth_prompt',
        'regex_scripts',
        'tavern_helper',
        'js_slash_runner',
        'javascript',
        'html',
        'iframe',
        'slash_commands',
        'regexes',
      };
      final unknownExtensionCount = extensions.keys
          .where((key) => !known.contains(key))
          .length;
      if (unknownExtensionCount > 0) {
        ignored.add('extensions.unknown');
        ignoredCounts['extensions.unknown'] =
            (ignoredCounts['extensions.unknown'] ?? 0) + unknownExtensionCount;
      }
    }

    for (final key in const [
      'temperature',
      'top_p',
      'top_k',
      'max_tokens',
      'model',
      'max_context',
      'stream',
    ]) {
      if (root.containsKey(key) || payload.containsKey(key)) {
        ignored.add(key);
        ignoredCounts[key] =
            (ignoredCounts[key] ?? 0) +
            (root.containsKey(key) &&
                    payload.containsKey(key) &&
                    !identical(root, payload)
                ? 2
                : 1);
      }
    }

    final uniqueIgnored = _unique(ignored);
    if (uniqueIgnored.isNotEmpty) {
      warnings.add('Unsupported character-card fields were ignored.');
    }
    if (promptParts.isEmpty) {
      warnings.add(
        'The character card has no description, personality, or scenario.',
      );
    }

    return CharacterCardImportResult(
      assistantDraft: CharacterCardAssistantDraft(
        name: name.trim().isEmpty ? 'Imported Character' : name.trim(),
        characterPrompt: promptParts.join('\n\n'),
        firstMessage: firstMessage,
      ),
      sourceFormat: sourceFormat,
      specVersion: _string(root['spec_version']).trim(),
      importedFields: _unique(imported),
      ignoredFields: uniqueIgnored,
      ignoredFieldCounts: Map.unmodifiable(ignoredCounts),
      warnings: _unique(warnings),
      embeddedWorldBook: embeddedBook,
      disabledWorldBookEntries: embeddedBook?.disabledEntryCount ?? 0,
      skippedWorldBookEntries: embeddedBook?.skippedEntryCount ?? 0,
      sourceFileName: sourceFileName,
    );
  }

  static CharacterCardWorldBookDraft? _parseWorldBook(
    Map<String, dynamic>? source, {
    required List<String> warnings,
    required List<String> imported,
  }) {
    if (source == null || !source.containsKey('entries')) return null;
    imported.add('character_book');
    final parsed = WorldBookImportService.parse({
      'character_book': source,
    }, policy: WorldBookImportPolicy.characterCard);
    if (parsed == null) return null;

    warnings.addAll(parsed.warnings);
    final entries = [
      for (final entry in parsed.book.entries)
        CharacterCardWorldBookEntryDraft(
          name: entry.name,
          content: entry.content,
          keywords: entry.keywords,
          enabled: entry.enabled,
          priority: entry.priority,
          position: entry.position,
          injectDepth: entry.injectDepth,
          role: entry.role,
          caseSensitive: entry.caseSensitive,
          scanDepth: entry.scanDepth,
          constantActive: entry.constantActive,
          requiresDisable: !entry.enabled,
        ),
    ];
    return CharacterCardWorldBookDraft(
      name: parsed.book.name,
      description: parsed.book.description,
      enabled: parsed.book.enabled,
      entries: List.unmodifiable(entries),
      warnings: List.unmodifiable(parsed.warnings),
      skippedEntryCount: parsed.skippedEntries,
    );
  }

  static CharacterCardSourceFormat _jsonFormat(Map<String, dynamic> root) {
    final spec = _string(root['spec']).toLowerCase();
    final version = _string(root['spec_version']).toLowerCase();
    if (spec.contains('v3') || version.startsWith('3')) {
      return CharacterCardSourceFormat.jsonV3;
    }
    if (spec.contains('v2') || version.startsWith('2') || root['data'] is Map) {
      return CharacterCardSourceFormat.jsonV2;
    }
    return CharacterCardSourceFormat.jsonV1;
  }

  static Uint8List _decodeBase64(String encoded) {
    final compact = encoded.replaceAll(RegExp(r'\s'), '');
    if (compact.isEmpty ||
        !RegExp(r'^[A-Za-z0-9+/_-]*={0,2}$').hasMatch(compact)) {
      throw const CharacterCardImportException(
        'Character metadata is not valid Base64.',
      );
    }
    final paddingStart = compact.indexOf('=');
    final unpadded = paddingStart < 0
        ? compact
        : compact.substring(0, paddingStart);
    final paddingLength = compact.length - unpadded.length;
    if (unpadded.length % 4 == 1 ||
        (paddingLength > 0 && compact.length % 4 != 0) ||
        (paddingLength > 0 && paddingLength != (4 - unpadded.length % 4) % 4)) {
      throw const CharacterCardImportException(
        'Character metadata is not valid Base64.',
      );
    }
    final normalized = unpadded.replaceAll('-', '+').replaceAll('_', '/');
    final requiredPadding = (4 - normalized.length % 4) % 4;
    try {
      final decoded = base64.decode('$normalized${'=' * requiredPadding}');
      if (decoded.length > maxJsonBytes) {
        throw const CharacterCardImportException(
          'Character metadata JSON exceeds the safety limit.',
        );
      }
      return Uint8List.fromList(decoded);
    } on FormatException {
      throw const CharacterCardImportException(
        'Character metadata is not valid Base64.',
      );
    }
  }

  static (String, String)? _decodeTextChunk(Uint8List chunk) {
    final separator = chunk.indexOf(0);
    if (separator <= 0 || separator > 79) return null;
    final key = _decodeAscii(chunk.sublist(0, separator));
    final value = _decodeUtf8(chunk.sublist(separator + 1));
    if (key == null || value == null) return null;
    return (key, value);
  }

  static (String, String)? _decodeInternationalTextChunk(Uint8List chunk) {
    final keywordEnd = chunk.indexOf(0);
    if (keywordEnd <= 0 || keywordEnd > 79 || chunk.length < keywordEnd + 3) {
      return null;
    }
    final key = _decodeAscii(chunk.sublist(0, keywordEnd));
    if (key == null) return null;
    var cursor = keywordEnd + 1;
    final compressionFlag = chunk[cursor++];
    final compressionMethod = chunk[cursor++];
    if (compressionFlag > 1 ||
        (compressionFlag == 1 && compressionMethod != 0)) {
      return null;
    }
    final languageEnd = chunk.indexOf(0, cursor);
    if (languageEnd < 0) return null;
    cursor = languageEnd + 1;
    final translatedEnd = chunk.indexOf(0, cursor);
    if (translatedEnd < 0) return null;
    cursor = translatedEnd + 1;
    var text = Uint8List.fromList(chunk.sublist(cursor));
    if (compressionFlag == 1) {
      try {
        final sink = _LimitedBytesSink(maxPngMetadataBytes);
        final decoder = ZLibCodec().decoder.startChunkedConversion(sink);
        decoder.add(text);
        decoder.close();
        if (sink.exceeded) {
          throw const CharacterCardImportException(
            'Compressed PNG character metadata exceeds the safety limit.',
          );
        }
        text = sink.takeBytes();
      } on CharacterCardImportException {
        rethrow;
      } catch (_) {
        return null;
      }
    }
    final value = _decodeUtf8(text);
    return value == null ? null : (key, value);
  }

  static String? _decodeAscii(List<int> bytes) {
    try {
      final value = ascii.decode(bytes, allowInvalid: false);
      return value;
    } on FormatException {
      return null;
    }
  }

  static String? _decodeAsciiRange(List<int> bytes, int start, int length) {
    for (var index = start; index < start + length; index++) {
      if (bytes[index] > 0x7f) return null;
    }
    return String.fromCharCodes(bytes.skip(start).take(length));
  }

  static String? _decodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return null;
    }
  }

  static bool _hasPngSignature(List<int> bytes) {
    const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  static int _uint32(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static String _fallbackName(String sourceFileName) {
    final value = p.basenameWithoutExtension(sourceFileName).trim();
    return value.isEmpty ? 'Imported Character' : value;
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  static String _string(dynamic value) => value is String ? value : '';

  static List<String> _unique(Iterable<String> values) => values
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList(growable: false);
}

class _LimitedBytesSink extends ByteConversionSink {
  _LimitedBytesSink(this.limit);

  final int limit;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  bool exceeded = false;

  @override
  void add(List<int> chunk) {
    if (exceeded) return;
    if (_builder.length + chunk.length > limit) {
      exceeded = true;
      return;
    }
    _builder.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}
