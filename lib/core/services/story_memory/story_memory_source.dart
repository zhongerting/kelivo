import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/assistant.dart';
import '../../models/chat_message.dart';
import '../chat/chat_service.dart';
import '../memory/memory_prompts.dart';
import '../../utils/model_visible_history.dart';

typedef StoryMemorySourceItem = ({ChatMessage message, int order});

final class StoryMemorySourceText {
  const StoryMemorySourceText({required this.text, required this.isComplete});

  final String text;
  final bool isComplete;
}

/// The selected message chain used by story-memory extraction and coverage
/// checks. Orders are logical positions in the selected version line, rather
/// than physical database row offsets. A regenerated version therefore keeps
/// its position while its id/version remains part of the digest.
final class StoryMemorySource {
  const StoryMemorySource._();

  static Future<List<StoryMemorySourceItem>> load(
    ChatService chatService,
    String conversationId,
  ) async {
    final count = await chatService.resolveMessageCount(conversationId);
    final selected = await chatService.loadSelectedContextMessages(
      conversationId,
      truncateIndex: -1,
      // The number of physical rows is an upper bound for the selected group
      // count, including all persisted versions.
      limit: count <= 0 ? 1 : count,
    );
    final result = <StoryMemorySourceItem>[];
    var order = 0;
    for (final message in selected) {
      if (message.isStreaming) continue;
      result.add((message: message, order: order));
      order++;
    }
    return result;
  }

  static List<StoryMemorySourceItem> range(
    List<StoryMemorySourceItem> source, {
    required int startOrder,
    required int endOrder,
  }) => [
    for (final item in source)
      if (item.order >= startOrder && item.order <= endOrder) item,
  ];

  /// Digest all identity and persisted part payloads, including reasoning and
  /// attachments. The extraction prompt may hide those parts, but a later
  /// edit must still invalidate a checkpoint that was based on the revision.
  static String digest(Iterable<StoryMemorySourceItem> items) {
    final canonical = [
      for (final item in items)
        {
          'order': item.order,
          'id': item.message.id,
          'groupId': item.message.groupId,
          'version': item.message.version,
          'role': item.message.role,
          'isStreaming': item.message.isStreaming,
          'parts': [
            for (final part in item.message.parts)
              {'kind': part.kind, 'payload': part.encodePayload()},
          ],
        },
    ];
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  static String buildConversationText(
    Iterable<StoryMemorySourceItem> items,
    MemoryPromptLang lang, {
    Assistant? assistant,
  }) => buildConversationTextResult(items, lang, assistant: assistant).text;

  static StoryMemorySourceText buildConversationTextResult(
    Iterable<StoryMemorySourceItem> items,
    MemoryPromptLang lang, {
    Assistant? assistant,
  }) {
    final userPrefix = lang == MemoryPromptLang.zh
        ? '\u7528\u6237\uff1a'
        : 'User: ';
    final assistantPrefix = lang == MemoryPromptLang.zh
        ? '\u52a9\u624b\uff1a'
        : 'Assistant: ';
    final lines = <String>[];
    var complete = true;
    for (final item in items) {
      final message = item.message;
      final prefix = switch (message.role) {
        'user' => userPrefix,
        'assistant' => assistantPrefix,
        _ => null,
      };
      if (prefix == null) {
        complete = false;
        continue;
      }
      if (message.isStreaming ||
          message.parts.any(
            (part) =>
                part.kind != 'text' &&
                part.kind != 'reasoning' &&
                part.kind != 'reply_options',
          ) ||
          message.parts.any(
            (part) =>
                part.kind == 'reasoning' &&
                part.encodePayload().trim().isNotEmpty,
          ) ||
          message.reasoningText?.trim().isNotEmpty == true ||
          message.reasoningSegmentsJson?.trim().isNotEmpty == true) {
        complete = false;
      }
      var text = ModelVisibleHistory.contentFor(
        message,
        assistant: assistant,
      ).trim();
      if (text.isEmpty) {
        // A pure thinking/options/attachment turn is not represented in the
        // text prompt. Keep its source range fail-open instead of claiming
        // that the generated summary covered it.
        complete = false;
        continue;
      }
      if (text.length > 4000) {
        complete = false;
        text = '${text.substring(0, 4000)}...';
      }
      lines.add('$prefix$text');
    }
    final joined = lines.join('\n\n');
    if (joined.length > 24000) {
      complete = false;
      return StoryMemorySourceText(
        text: '...${joined.substring(joined.length - 24000)}',
        isComplete: false,
      );
    }
    return StoryMemorySourceText(text: joined, isComplete: complete);
  }
}
