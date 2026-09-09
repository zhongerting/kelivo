/// The fixed protocol used by the RP reply-options feature.
const String replyOptionsStartTag = '<kelivo_options>';
const String replyOptionsEndTag = '</kelivo_options>';
const String replyOptionStartTag = '<option>';
const String replyOptionEndTag = '</option>';

/// Maximum number of UTF-16 code units occupied by the protocol block.
///
/// This is deliberately much larger than a normal six-option response while
/// keeping malformed provider output from growing without bound while it is
/// held in the streaming state.
const int replyOptionsMaxBlockLength = 64 * 1024;

final class ReplyOptionsParseResult {
  const ReplyOptionsParseResult({
    required this.body,
    required this.options,
    required this.markerDetected,
    required this.valid,
  });

  final String body;
  final List<String> options;
  final bool markerDetected;
  final bool valid;
}

final class ReplyOptionsStreamingView {
  const ReplyOptionsStreamingView({
    required this.body,
    required this.markerDetected,
  });

  final String body;
  final bool markerDetected;
}

/// Parse the accumulated assistant text for the currently visible body.
///
/// Options are intentionally never returned by this method. Once the exact
/// opening marker is present, everything from that marker onward is withheld
/// until the final parse. Before the marker is complete, a suffix that could
/// still become the opening marker is also withheld so split network chunks do
/// not briefly render protocol text in the assistant bubble.
ReplyOptionsStreamingView parseReplyOptionsStreaming(String rawText) {
  final markerIndex = rawText.indexOf(replyOptionsStartTag);
  if (markerIndex >= 0) {
    return ReplyOptionsStreamingView(
      body: rawText.substring(0, markerIndex),
      markerDetected: true,
    );
  }

  final withheldLength = _partialOpeningTagLength(rawText);
  return ReplyOptionsStreamingView(
    body: withheldLength == 0
        ? rawText
        : rawText.substring(0, rawText.length - withheldLength),
    markerDetected: false,
  );
}

/// Parse a completed assistant response.
///
/// The parser only recognizes the exact fixed tags above. A detected but
/// malformed or oversized block is removed from the returned body and does
/// not produce options, which prevents protocol text from entering later
/// model context.
ReplyOptionsParseResult parseReplyOptionsFinal(String rawText) {
  final start = rawText.indexOf(replyOptionsStartTag);
  if (start < 0) {
    return ReplyOptionsParseResult(
      body: rawText,
      options: const <String>[],
      markerDetected: false,
      valid: false,
    );
  }

  final blockStart = start + replyOptionsStartTag.length;
  final end = rawText.indexOf(replyOptionsEndTag, blockStart);
  final body = rawText.substring(0, start).trimRight();

  if (end < 0 || end - blockStart > replyOptionsMaxBlockLength) {
    return ReplyOptionsParseResult(
      body: body,
      options: const <String>[],
      markerDetected: true,
      valid: false,
    );
  }

  final trailing = rawText.substring(end + replyOptionsEndTag.length);
  if (trailing.trim().isNotEmpty) {
    return ReplyOptionsParseResult(
      body: body,
      options: const <String>[],
      markerDetected: true,
      valid: false,
    );
  }

  final parsed = _parseOptionBlock(rawText.substring(blockStart, end));
  if (parsed == null || parsed.isEmpty) {
    return ReplyOptionsParseResult(
      body: body,
      options: const <String>[],
      markerDetected: true,
      valid: false,
    );
  }

  return ReplyOptionsParseResult(
    body: body,
    options: parsed,
    markerDetected: true,
    valid: true,
  );
}

List<String>? _parseOptionBlock(String block) {
  final options = <String>[];
  final seen = <String>{};
  var cursor = 0;

  while (cursor < block.length) {
    while (cursor < block.length && block[cursor].trim().isEmpty) {
      cursor++;
    }
    if (cursor == block.length) break;

    if (!block.startsWith(replyOptionStartTag, cursor)) return null;
    cursor += replyOptionStartTag.length;
    final end = block.indexOf(replyOptionEndTag, cursor);
    if (end < 0) return null;

    final option = block.substring(cursor, end).trim();
    if (option.isNotEmpty && seen.add(option) && options.length < 6) {
      options.add(option);
    }
    cursor = end + replyOptionEndTag.length;
  }

  return options;
}

int _partialOpeningTagLength(String rawText) {
  final maximum = rawText.length < replyOptionsStartTag.length - 1
      ? rawText.length
      : replyOptionsStartTag.length - 1;
  for (var length = maximum; length > 0; length--) {
    if (rawText.endsWith(replyOptionsStartTag.substring(0, length))) {
      return length;
    }
  }
  return 0;
}
