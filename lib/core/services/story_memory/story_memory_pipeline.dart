import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../models/assistant.dart';
import '../../providers/assistant_provider.dart';
import '../../providers/settings_provider.dart';
import '../api/chat_api_service.dart';
import '../chat/chat_service.dart';
import 'story_memory_models.dart';
import 'story_memory_prompt.dart';
import 'story_memory_repository.dart';
import 'story_memory_source.dart';

final class StoryMemoryOrganizeResult {
  const StoryMemoryOrganizeResult({
    required this.advanced,
    this.error,
    this.operationCount = 0,
    this.sourceStartOrder,
    this.sourceEndOrder,
    this.pendingPatchId,
  });

  final bool advanced;
  final String? error;
  final int operationCount;
  final int? sourceStartOrder;
  final int? sourceEndOrder;
  final String? pendingPatchId;
}

final class StoryMemoryOrganizeStatus {
  const StoryMemoryOrganizeStatus({this.lastAt, this.lastResult});

  final DateTime? lastAt;
  final StoryMemoryOrganizeResult? lastResult;
}

final class _StoryMemoryJob {
  _StoryMemoryJob({
    required this.conversationId,
    required this.assistantId,
    required this.force,
    this.completer,
    this.onError,
  });

  final String conversationId;
  final String assistantId;
  final bool force;
  final Completer<StoryMemoryOrganizeResult>? completer;
  final void Function(String error)? onError;
}

/// Background extractor for conversation-scoped novel/RP memory.
///
/// It intentionally does not share the user-memory repository or watermark.
/// The queue is best effort and all durable progress is defined by the story
/// repository's valid checkpoint transaction.
final class StoryMemoryPipelineService {
  StoryMemoryPipelineService({
    required this.chatService,
    required this.repository,
    required this.settings,
    required this.assistants,
    Future<String> Function({
      required ProviderConfig config,
      required String modelId,
      required String prompt,
      String? conversationId,
      int? thinkingBudget,
    })?
    generateText,
  }) : _generateText = generateText ?? _defaultGenerateText;

  static Future<String> _defaultGenerateText({
    required ProviderConfig config,
    required String modelId,
    required String prompt,
    String? conversationId,
    int? thinkingBudget,
  }) => ChatApiService.generateText(
    conversationId: conversationId,
    config: config,
    modelId: modelId,
    prompt: prompt,
    thinkingBudget: thinkingBudget,
    skipImageParsing: true,
  );

  final ChatService chatService;
  final StoryMemoryRepository repository;
  final SettingsProvider Function() settings;
  final AssistantProvider Function() assistants;
  final Future<String> Function({
    required ProviderConfig config,
    required String modelId,
    required String prompt,
    String? conversationId,
    int? thinkingBudget,
  })
  _generateText;

  static const int queueLimit = 8;
  static const int maxWindowTurns = 8;
  static const skipReasonCodes = <String>{
    'temporary_conversation',
    'story_memory_disabled',
    'story_auto_organize_off',
    'story_streaming',
    'story_below_threshold',
    'story_empty_window',
    'confirmation_required',
    'story_source_text_incomplete',
  };

  final Queue<_StoryMemoryJob> _queue = Queue<_StoryMemoryJob>();
  bool _running = false;
  StoryMemoryOrganizeStatus _lastStatus = const StoryMemoryOrganizeStatus();

  StoryMemoryOrganizeStatus get lastStatus => _lastStatus;

  void scheduleIfNeeded({
    required String conversationId,
    required String assistantId,
    void Function(String error)? onError,
  }) {
    try {
      _enqueue(
        _StoryMemoryJob(
          conversationId: conversationId,
          assistantId: assistantId,
          force: false,
          onError: onError,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('StoryMemory.scheduleIfNeeded: $error\n$stackTrace');
      onError?.call(error.toString());
    }
  }

  Future<StoryMemoryOrganizeResult> runNow({
    required String conversationId,
    required String assistantId,
  }) {
    final completer = Completer<StoryMemoryOrganizeResult>();
    _enqueue(
      _StoryMemoryJob(
        conversationId: conversationId,
        assistantId: assistantId,
        force: true,
        completer: completer,
      ),
    );
    return completer.future;
  }

  void _enqueue(_StoryMemoryJob job) {
    if (chatService.isTemporaryConversation(job.conversationId)) {
      _complete(
        job,
        const StoryMemoryOrganizeResult(
          advanced: false,
          error: 'temporary_conversation',
        ),
      );
      return;
    }
    _queue.removeWhere(
      (pending) =>
          pending.conversationId == job.conversationId &&
          pending.completer == null &&
          job.completer == null,
    );
    _queue.addLast(job);
    while (_queue.length > queueLimit) {
      final dropped = _queue.removeFirst();
      _complete(
        dropped,
        const StoryMemoryOrganizeResult(
          advanced: false,
          error: 'queue_overflow',
        ),
      );
    }
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeFirst();
        StoryMemoryOrganizeResult result;
        try {
          result = await _run(job);
        } catch (error, stackTrace) {
          debugPrint('StoryMemory job failed: $error\n$stackTrace');
          result = StoryMemoryOrganizeResult(
            advanced: false,
            error: error.toString(),
          );
        }
        _lastStatus = StoryMemoryOrganizeStatus(
          lastAt: DateTime.now(),
          lastResult: result,
        );
        _complete(job, result);
      }
    } finally {
      _running = false;
    }
  }

  void _complete(_StoryMemoryJob job, StoryMemoryOrganizeResult result) {
    if (result.error != null && !skipReasonCodes.contains(result.error)) {
      job.onError?.call(result.error!);
    }
    if (job.completer != null && !job.completer!.isCompleted) {
      job.completer!.complete(result);
    }
  }

  Future<StoryMemoryOrganizeResult> _run(_StoryMemoryJob job) async {
    final assistant = assistants().getById(job.assistantId);
    if (assistant == null) {
      return const StoryMemoryOrganizeResult(
        advanced: false,
        error: 'assistant_missing',
      );
    }
    if (!assistant.enableStoryMemory) {
      return const StoryMemoryOrganizeResult(
        advanced: false,
        error: 'story_memory_disabled',
      );
    }
    if (!job.force && !assistant.autoOrganizeStoryMemory) {
      return const StoryMemoryOrganizeResult(
        advanced: false,
        error: 'story_auto_organize_off',
      );
    }
    final conversation = chatService.getConversation(job.conversationId);
    if (conversation == null) {
      return const StoryMemoryOrganizeResult(
        advanced: false,
        error: 'conversation_missing',
      );
    }
    if (chatService.getMessages(job.conversationId).any((m) => m.isStreaming)) {
      return const StoryMemoryOrganizeResult(
        advanced: false,
        error: 'story_streaming',
      );
    }
    final source = await StoryMemorySource.load(chatService, conversation.id);
    if (source.isEmpty) {
      return const StoryMemoryOrganizeResult(
        advanced: false,
        error: 'story_empty_window',
      );
    }
    var coverage = await repository.inspectCoverage(conversation.id, source);
    if (coverage.staleFromOrder != null || coverage.hasHole) {
      final recoveryOrder =
          coverage.staleFromOrder ??
          (coverage.coveredEndOrder >= source.first.order
              ? coverage.coveredEndOrder + 1
              : source.first.order);
      await repository.markStaleFromOrder(
        conversationId: conversation.id,
        order: recoveryOrder,
      );
      // Re-read after invalidation so a manual organize or the first retry
      // after an edit can rebuild immediately. If invalid coverage remains,
      // fail open and leave the source watermark untouched.
      coverage = await repository.inspectCoverage(conversation.id, source);
      if (coverage.staleFromOrder != null || coverage.hasHole) {
        return const StoryMemoryOrganizeResult(
          advanced: false,
          error: 'story_source_stale',
        );
      }
    }
    final pending = [
      for (final item in source)
        if (item.order > coverage.coveredEndOrder) item,
    ];
    final pendingTurns = pending
        .where((item) => item.message.role == 'assistant')
        .length;
    if (!job.force &&
        pendingTurns <
            assistant.storyMemoryOrganizeEveryNTurns.clamp(
              Assistant.minStoryMemoryOrganizeEveryNTurns,
              Assistant.maxStoryMemoryOrganizeEveryNTurns,
            )) {
      return const StoryMemoryOrganizeResult(
        advanced: false,
        error: 'story_below_threshold',
      );
    }
    if (pending.isEmpty) {
      return const StoryMemoryOrganizeResult(
        advanced: false,
        error: 'story_empty_window',
      );
    }
    final window = <StoryMemorySourceItem>[];
    var assistantCount = 0;
    for (final item in pending) {
      window.add(item);
      if (item.message.role == 'assistant') assistantCount++;
      if (assistantCount >= maxWindowTurns) break;
    }
    final start = window.first.order;
    final end = window.last.order;
    final sourceDigest = StoryMemorySource.digest(window);
    final appSettings = settings();
    final sourceText = StoryMemorySource.buildConversationTextResult(
      window,
      appSettings.resolvedMemoryPromptLang,
      assistant: assistant,
    );
    if (!sourceText.isComplete) {
      return StoryMemoryOrganizeResult(
        advanced: false,
        error: 'story_source_text_incomplete',
        sourceStartOrder: start,
        sourceEndOrder: end,
      );
    }
    final current = await repository.read(conversation.id);
    final existingPending = current.pendingPatches
        .where(
          (pendingPatch) =>
              pendingPatch.isPending &&
              pendingPatch.patch.sourceStartOrder == start &&
              pendingPatch.patch.sourceEndOrder == end &&
              pendingPatch.patch.sourceDigest == sourceDigest,
        )
        .firstOrNull;
    if (existingPending != null) {
      if (assistant.storyMemoryRequireConfirmation) {
        return StoryMemoryOrganizeResult(
          advanced: false,
          error: 'confirmation_required',
          operationCount: existingPending.patch.operations.length,
          sourceStartOrder: start,
          sourceEndOrder: end,
          pendingPatchId: existingPending.id,
        );
      }
      final committed = await repository.confirmPendingPatch(
        pendingId: existingPending.id,
        source: source,
      );
      return StoryMemoryOrganizeResult(
        advanced: true,
        operationCount: existingPending.patch.operations.length,
        sourceStartOrder: committed.sourceStartOrder,
        sourceEndOrder: committed.sourceEndOrder,
      );
    }
    final providerKey = appSettings.memoryModelProvider;
    final modelId = appSettings.memoryModelId;
    if (providerKey == null || modelId == null) {
      return const StoryMemoryOrganizeResult(
        advanced: false,
        error: 'memory_model_unset',
      );
    }
    final config = appSettings.getProviderConfig(providerKey);
    if (config.models.isNotEmpty &&
        !config.models.contains(modelId) &&
        config.modelOverrides[modelId] == null) {
      return const StoryMemoryOrganizeResult(
        advanced: false,
        error: 'memory_model_missing',
      );
    }
    final prompt = StoryMemoryPromptBuilder.build(
      lang: appSettings.resolvedMemoryPromptLang,
      conversationId: conversation.id,
      assistant: assistant,
      snapshot: current,
      sourceWindow: window,
      sourceStartOrder: start,
      sourceEndOrder: end,
      sourceDigest: sourceDigest,
    );
    final thinkingBudget = appSettings.memoryModelThinkingEnabled
        ? (assistant.thinkingBudget ?? appSettings.thinkingBudget)
        : 0;
    final raw = await _generateText(
      conversationId: conversation.id,
      config: config,
      modelId: modelId,
      prompt: prompt,
      thinkingBudget: thinkingBudget,
    );
    final patch = StoryMemoryPatch.parse(raw);
    if (patch.conversationId != conversation.id ||
        patch.sourceStartOrder != start ||
        patch.sourceEndOrder != end ||
        patch.sourceDigest != sourceDigest) {
      return const StoryMemoryOrganizeResult(
        advanced: false,
        error: 'story_patch_source_mismatch',
      );
    }
    if (assistant.storyMemoryRequireConfirmation) {
      final pendingPatch = await repository.savePendingPatch(
        patch: patch,
        source: source,
      );
      return StoryMemoryOrganizeResult(
        advanced: false,
        error: 'confirmation_required',
        operationCount: patch.operations.length,
        sourceStartOrder: patch.sourceStartOrder,
        sourceEndOrder: patch.sourceEndOrder,
        pendingPatchId: pendingPatch.id,
      );
    }
    final committed = await repository.applyPatch(patch: patch, source: source);
    return StoryMemoryOrganizeResult(
      advanced: true,
      operationCount: patch.operations.length,
      sourceStartOrder: committed.sourceStartOrder,
      sourceEndOrder: committed.sourceEndOrder,
    );
  }
}
