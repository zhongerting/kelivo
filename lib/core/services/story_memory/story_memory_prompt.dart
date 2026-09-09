import 'dart:convert';

import '../../models/assistant.dart';
import '../memory/memory_prompts.dart';
import 'story_memory_models.dart';
import 'story_memory_source.dart';

final class StoryMemoryPromptBuilder {
  StoryMemoryPromptBuilder._();

  static String build({
    required MemoryPromptLang lang,
    required String conversationId,
    required Assistant assistant,
    required StoryMemorySnapshot snapshot,
    required List<StoryMemorySourceItem> sourceWindow,
    required int sourceStartOrder,
    required int sourceEndOrder,
    required String sourceDigest,
  }) {
    final current = jsonEncode(snapshot.toPromptJson(currentOnly: true));
    final window = StoryMemorySource.buildConversationText(
      sourceWindow,
      lang,
      assistant: assistant,
    );
    final languageNote = lang == MemoryPromptLang.zh
        ? 'Use concise factual English or the language used by the story.'
        : 'Use concise factual text in the language used by the story.';
    return '''You are the story-memory editor for a long-running novel or roleplay.
Return exactly one JSON object and nothing else. Do not use Markdown fences.
Never output SQL, Dart, JavaScript, tool calls, or table-edit commands.

Conversation id: $conversationId
Source window: $sourceStartOrder..$sourceEndOrder
Source digest: $sourceDigest
$languageNote

Rules:
- Preserve facts from the existing memory unless the source window clearly changes them.
- Character core traits and any locked character field are read-only. Do not output lockedFields.
- Character state is temporary state, not permanent personality.
- Events are append-only. Do not delete or rewrite an old event.
- Use existing character IDs when referring to characters. New character IDs must be unique strings.
- Every character/state/relationship update must use the exact operation shape below.
- Include exactly one appendPlotSummary operation covering the complete source window.
- sourceMessageIds in that summary must be the ordered message IDs from the source window.
- If no useful fact changed, still append a faithful plot summary and do not invent facts.

Existing story memory JSON:
$current

Source conversation:
$window

Allowed JSON shape:
{
  "schemaVersion": 1,
  "conversationId": "$conversationId",
  "sourceStartOrder": $sourceStartOrder,
  "sourceEndOrder": $sourceEndOrder,
  "sourceDigest": "$sourceDigest",
  "operations": [
    {"op":"upsertCharacter","characterId":"...","fields":{"name":"..."}},
    {"op":"upsertCharacterState","characterId":"...","fields":{"location":"..."}},
    {"op":"upsertRelationship","relationshipId":"...","fields":{"fromCharacterId":"...","toCharacterId":"...","relationType":"..."}},
    {"op":"appendEvent","row":{"eventId":"...","participants":["..."],"summary":"..."}},
    {"op":"appendPlotSummary","row":{"summaryId":"...","sourceStartOrder":$sourceStartOrder,"sourceEndOrder":$sourceEndOrder,"sourceDigest":"$sourceDigest","sourceMessageIds":["..."],"summary":"...","keyEntities":[],"unresolvedThreads":[]}}
  ]
}
''';
  }
}
