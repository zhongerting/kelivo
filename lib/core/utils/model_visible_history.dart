import '../models/assistant.dart';
import '../models/chat_message.dart';
import 'thinking_tag_parser.dart';

typedef ModelVisibleHistoryContentTransform =
    String Function(ChatMessage message);

/// Produces text for model-facing secondary prompts without changing history.
///
/// This is deliberately limited to completed assistant messages and the
/// inline thinking syntax Kelivo already understands. Structured provider
/// artifacts are handled by the API message builder, where their protocol
/// shape is available; this class never rewrites persisted message parts.
class ModelVisibleHistory {
  const ModelVisibleHistory._();

  static String contentFor(
    ChatMessage message, {
    Assistant? assistant,
    bool? excludeThinking,
    String? processingMessageId,
  }) {
    final shouldExclude =
        excludeThinking ?? assistant?.excludeThinkingFromContext == true;
    if (!shouldExclude ||
        message.role != 'assistant' ||
        message.isStreaming ||
        (processingMessageId != null && message.id == processingMessageId)) {
      return message.content;
    }
    return visibleText(message.content);
  }

  /// Filter inline thinking from an already-built API/text string.
  static String visibleText(String content) {
    if (content.isEmpty) return content;
    return ThinkingTagParser.parseWithRanges(content).visibleContent;
  }

  static ModelVisibleHistoryContentTransform transformFor(
    Assistant? assistant, {
    String? processingMessageId,
  }) {
    return (message) => contentFor(
      message,
      assistant: assistant,
      processingMessageId: processingMessageId,
    );
  }
}
