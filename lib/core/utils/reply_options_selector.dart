import '../models/chat_message.dart';
import '../models/message_part.dart';

/// Returns the options belonging to the currently selected final assistant
/// reply, or an empty list when the panel must stay hidden.
List<String> selectReplyOptions({
  required Iterable<ChatMessage> messages,
  required Map<String, int> versionSelections,
  required String? assistantId,
  String? conversationId,
  bool conversationSwitching = false,
  bool assistantSwitching = false,
  bool selectingMessages = false,
  bool sending = false,
}) {
  if (assistantId == null ||
      assistantId.isEmpty ||
      conversationSwitching ||
      assistantSwitching ||
      selectingMessages ||
      sending) {
    return const <String>[];
  }

  final collapsed = _collapseVersions(
    messages.where(
      (message) =>
          conversationId == null || message.conversationId == conversationId,
    ),
    versionSelections,
  );
  if (collapsed.isEmpty) return const <String>[];

  final last = collapsed.last;
  if (last.role != 'assistant' || last.isStreaming) {
    return const <String>[];
  }
  for (final part in last.parts.reversed) {
    if (part is ReplyOptionsPart && part.assistantId == assistantId) {
      return part.options;
    }
  }
  return const <String>[];
}

List<ChatMessage> _collapseVersions(
  Iterable<ChatMessage> messages,
  Map<String, int> versionSelections,
) {
  final byGroup = <String, List<ChatMessage>>{};
  final order = <String>[];
  for (final message in messages) {
    final groupId = message.groupId ?? message.id;
    byGroup
        .putIfAbsent(groupId, () {
          order.add(groupId);
          return <ChatMessage>[];
        })
        .add(message);
  }

  final collapsed = <ChatMessage>[];
  for (final groupId in order) {
    final versions = byGroup[groupId]!
      ..sort((left, right) => left.version.compareTo(right.version));
    final selectedVersion = versionSelections[groupId];
    ChatMessage? selected;
    if (selectedVersion != null) {
      for (final version in versions) {
        if (version.version == selectedVersion) {
          selected = version;
          break;
        }
      }
    }
    collapsed.add(selected ?? versions.last);
  }
  return collapsed;
}
