import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/api/providers/claude/claude_history.dart';
import 'package:Kelivo/core/services/api/providers/google/gemini_thought_signature.dart';
import 'package:Kelivo/core/services/logging/context_log_models.dart';
import 'package:Kelivo/core/services/logging/context_logger.dart';
import 'package:Kelivo/core/utils/multimodal_input_utils.dart';
import 'package:Kelivo/features/home/services/message_builder_service.dart';

class _FakeBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChatService extends ChatService {
  _FakeChatService({this.toolEvents = const {}});

  final Map<String, List<Map<String, dynamic>>> toolEvents;

  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) =>
      List<Map<String, dynamic>>.of(toolEvents[assistantMessageId] ?? const []);

  @override
  List<ChatMessage> getMessages(String conversationId) => const [];
}

ChatMessage _message({
  required String id,
  required String role,
  required String content,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: 'conversation-1',
  );
}

MessageBuilderService _service({
  Map<String, List<Map<String, dynamic>>> toolEvents = const {},
  String? Function(ChatMessage message, String kind)? providerArtifactLookup,
}) => MessageBuilderService(
  chatService: _FakeChatService(toolEvents: toolEvents),
  contextProvider: _FakeBuildContext(),
  providerArtifactLookup: providerArtifactLookup,
);

void main() {
  setUp(() async {
    await ContextLogger.setEnabled(false);
  });

  tearDown(() async {
    await ContextLogger.setEnabled(false);
  });

  test(
    'filters inline thinking from every completed assistant history turn',
    () {
      final service = _service();
      final persisted = [
        _message(id: 'u1', role: 'user', content: 'first'),
        _message(
          id: 'a1',
          role: 'assistant',
          content:
              'before<think>one</think>middle<THINK></THINK>after'
              '<|channel>thoughttwo<channel|>',
        ),
        _message(
          id: 'a2',
          role: 'assistant',
          content: '<thinking>only reasoning</thinking>',
        ),
        _message(
          id: 'a3',
          role: 'assistant',
          content: 'visible<thought>unfinished',
        ),
        _message(id: 'u2', role: 'user', content: 'second'),
        _message(id: 'a4', role: 'assistant', content: 'plain response'),
      ];
      final originalA1 = persisted[1].content;
      final apiMessages = service.buildApiMessages(
        messages: persisted,
        versionSelections: const {},
        currentConversation: Conversation(title: 'test'),
      );

      service.filterHistoricalThinkingForContext(
        apiMessages,
        assistant: const Assistant(
          id: 'rp-1',
          name: 'RP',
          mode: AssistantMode.roleplay,
          excludeThinkingFromContext: true,
        ),
      );

      expect(apiMessages.map((message) => message['content']), [
        'first',
        'beforemiddleafter',
        'visible',
        'second',
        'plain response',
      ]);
      expect(persisted[1].content, originalA1);
    },
  );

  test('keeps the currently processing assistant turn unchanged', () {
    final service = _service();
    final apiMessages = service.buildApiMessages(
      messages: [
        _message(
          id: 'a1',
          role: 'assistant',
          content: '<think>old</think>done',
        ),
        _message(
          id: 'current',
          role: 'assistant',
          content: '<think>active plan</think>active answer',
        ),
      ],
      versionSelections: const {},
      currentConversation: Conversation(title: 'test'),
    );

    service.filterHistoricalThinkingForContext(
      apiMessages,
      assistant: const Assistant(
        id: 'rp-1',
        name: 'RP',
        excludeThinkingFromContext: true,
      ),
      processingMessageId: 'current',
    );

    expect(apiMessages[0]['content'], 'done');
    expect(
      apiMessages[1]['content'],
      '<think>active plan</think>active answer',
    );
  });

  test('does nothing when the assistant switch is disabled', () {
    final service = _service();
    final apiMessages = <Map<String, dynamic>>[
      {'role': 'assistant', 'content': '<think>keep</think>visible'},
    ];

    service.filterHistoricalThinkingForContext(
      apiMessages,
      assistant: const Assistant(id: 'normal-1', name: 'Normal'),
    );

    expect(apiMessages.single['content'], '<think>keep</think>visible');
  });

  test('context logger records the filtered text and length', () async {
    await ContextLogger.setEnabled(true);
    final service = _service();
    final apiMessages = service.buildApiMessages(
      messages: [
        _message(id: 'u1', role: 'user', content: 'question'),
        _message(
          id: 'a1',
          role: 'assistant',
          content: '<think>long internal plan</think>short answer',
        ),
      ],
      versionSelections: const {},
      currentConversation: Conversation(title: 'test'),
    );

    service.filterHistoricalThinkingForContext(
      apiMessages,
      assistant: const Assistant(
        id: 'rp-1',
        name: 'RP',
        excludeThinkingFromContext: true,
      ),
    );

    final snapshot = ContextLogger.buildSnapshot(
      apiMessages: apiMessages,
      conversationId: 'conversation-1',
      assistantName: 'RP',
      provider: 'test',
      model: 'model',
    );
    final assistantMessage = snapshot.messages.last;
    expect(assistantMessage.segments.single.source, ContextSource.chatHistory);
    expect(assistantMessage.segments.single.text, 'short answer');
    expect(assistantMessage.segments.single.text.length, 'short answer'.length);
  });

  test('removes readable structured reasoning but keeps opaque artifacts', () {
    final service = _service();
    final apiMessages = service.buildApiMessages(
      messages: [
        _message(id: 'u1', role: 'user', content: 'question'),
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'answer',
          conversationId: 'conversation-1',
          reasoningText: 'private plan',
          reasoningSegmentsJson:
              '{"reasoningDetails":['
              '{"type":"reasoning.text","text":"private plan",'
              '"signature":"sig-1"},'
              '{"type":"reasoning.encrypted","data":"opaque"},'
              '{"type":"reasoning.summary","summary":"private summary"}]}',
        ),
      ],
      versionSelections: const {},
      currentConversation: Conversation(title: 'test'),
    );

    service.filterStructuredThinkingForContext(
      apiMessages,
      assistant: const Assistant(
        id: 'rp-1',
        name: 'RP',
        excludeThinkingFromContext: true,
      ),
    );

    final assistant = apiMessages.last;
    expect(assistant.containsKey('reasoning_content'), isFalse);
    expect(assistant.containsKey('reasoning'), isFalse);
    expect(assistant['reasoning_details'], [
      {'type': 'reasoning.text', 'signature': 'sig-1'},
      {'type': 'reasoning.encrypted', 'data': 'opaque'},
    ]);
  });

  test('does not remove structured reasoning from the processing turn', () {
    final service = _service();
    final apiMessages = service.buildApiMessages(
      messages: [
        ChatMessage(
          id: 'current',
          role: 'assistant',
          content: 'active',
          conversationId: 'conversation-1',
          reasoningText: 'active plan',
          reasoningSegmentsJson:
              '{"reasoningDetails":[{"type":"reasoning.text",'
              '"text":"active plan","signature":"sig-active"}]}',
        ),
      ],
      versionSelections: const {},
      currentConversation: Conversation(title: 'test'),
    );

    service.filterStructuredThinkingForContext(
      apiMessages,
      assistant: const Assistant(
        id: 'rp-1',
        name: 'RP',
        excludeThinkingFromContext: true,
      ),
      processingMessageId: 'current',
    );

    expect(apiMessages.single['reasoning_content'], 'active plan');
    expect(
      (apiMessages.single['reasoning_details'] as List).single['text'],
      'active plan',
    );
  });

  test(
    'filters completed Claude thinking blocks without breaking tool pairs',
    () {
      const claudeTurn =
          '[[{"type":"thinking","thinking":"private","signature":"sig"},'
          '{"type":"tool_use","id":"call-1","name":"lookup",'
          '"input":{"q":"Kelivo"}}]]';
      final service = _service(
        toolEvents: {
          'a1': [
            {
              'id': 'call-1',
              'name': 'lookup',
              'arguments': '{"q":"Kelivo"}',
              'content': '{"ok":true}',
              'metadata': {
                'anthropic': {
                  'assistant_blocks': [
                    {
                      'type': 'thinking',
                      'thinking': 'private',
                      'signature': 'sig',
                    },
                    {
                      'type': 'tool_use',
                      'id': 'call-1',
                      'name': 'lookup',
                      'input': {'q': 'Kelivo'},
                    },
                  ],
                },
              },
            },
          ],
        },
        providerArtifactLookup: (message, kind) =>
            message.id == 'a1' && kind == claudeTurnArtifactKind
            ? claudeTurn
            : null,
      );
      final apiMessages = service.buildApiMessages(
        messages: [
          _message(id: 'u1', role: 'user', content: 'lookup'),
          _message(id: 'a1', role: 'assistant', content: 'answer'),
        ],
        versionSelections: const {},
        currentConversation: Conversation(title: 'test'),
        includeToolMessages: true,
      );

      service.filterStructuredThinkingForContext(
        apiMessages,
        assistant: const Assistant(
          id: 'rp-1',
          name: 'RP',
          excludeThinkingFromContext: true,
        ),
      );

      final toolAssistant = apiMessages.firstWhere(
        (message) => message['tool_calls'] is List,
      );
      final artifact = toolAssistant[multimodalInternalClaudeTurnKey] as String;
      final artifactBlocks = (jsonDecode(artifact) as List).first as List;
      expect(artifactBlocks.map((block) => block['type']), ['tool_use']);
      final callMetadata =
          ((toolAssistant['tool_calls'] as List).single as Map)['metadata']
              as Map;
      final metadataBlocks =
          (callMetadata['anthropic']['assistant_blocks'] as List);
      expect(metadataBlocks.map((block) => block['type']), ['tool_use']);
      expect(apiMessages.any((message) => message['role'] == 'tool'), isTrue);
    },
  );

  test(
    'preserves Gemini thought signatures while filtering readable fields',
    () {
      final service = _service(
        providerArtifactLookup: (message, kind) =>
            kind == geminiThoughtSignatureArtifactKind ? 'sig-gemini' : null,
      );
      final apiMessages = service.buildApiMessages(
        messages: [
          _message(
            id: 'a1',
            role: 'assistant',
            content: '<think>x</think>answer',
          ),
        ],
        versionSelections: const {},
        currentConversation: Conversation(title: 'test'),
      );

      service.filterHistoricalThinkingForContext(
        apiMessages,
        assistant: const Assistant(
          id: 'rp-1',
          name: 'RP',
          excludeThinkingFromContext: true,
        ),
      );
      service.filterStructuredThinkingForContext(
        apiMessages,
        assistant: const Assistant(
          id: 'rp-1',
          name: 'RP',
          excludeThinkingFromContext: true,
        ),
      );

      expect(apiMessages.single['content'], 'answer');
      expect(
        apiMessages.single[multimodalInternalGeminiThoughtSignatureKey],
        'sig-gemini',
      );
    },
  );
}
