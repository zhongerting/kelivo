import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/story_memory/story_memory_models.dart';
import '../../../core/services/story_memory/story_memory_pipeline.dart';
import '../../../core/services/story_memory/story_memory_repository.dart';
import '../../../core/services/story_memory/story_memory_source.dart';
import '../../../icons/lucide_adapter.dart';

final class StoryMemoryPage extends StatefulWidget {
  const StoryMemoryPage({
    super.key,
    required this.conversationId,
    required this.assistantId,
  });

  final String conversationId;
  final String assistantId;

  @override
  State<StoryMemoryPage> createState() => _StoryMemoryPageState();
}

class _StoryMemoryPageState extends State<StoryMemoryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  StoryMemorySnapshot? _snapshot;
  bool _loading = true;
  bool _organizing = false;
  String _query = '';

  bool get _isZh => Localizations.localeOf(context).languageCode == 'zh';

  String _t(String en, String zh) => _isZh ? zh : en;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: StoryMemoryTable.values.length, vsync: this);
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final snapshot = await context.read<StoryMemoryRepository>().read(
        widget.conversationId,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage('$error');
    }
  }

  Future<void> _organize() async {
    if (_organizing) return;
    setState(() => _organizing = true);
    try {
      final result = await context.read<StoryMemoryPipelineService>().runNow(
        conversationId: widget.conversationId,
        assistantId: widget.assistantId,
      );
      if (!mounted) return;
      if (result.error != null) _showMessage(result.error!);
      await _reload();
    } finally {
      if (mounted) setState(() => _organizing = false);
    }
  }

  Future<void> _confirmPending(StoryMemoryPendingPatch pending) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Apply memory changes?', '应用记忆变更？')),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: SelectableText(
              const JsonEncoder.withIndent(
                '  ',
              ).convert(pending.patch.toJson()),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_t('Cancel', '取消')),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Lucide.Check, size: 18),
            label: Text(_t('Apply', '应用')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final chatService = context.read<ChatService>();
      final repository = context.read<StoryMemoryRepository>();
      final source = await StoryMemorySource.load(
        chatService,
        widget.conversationId,
      );
      await repository.confirmPendingPatch(
        pendingId: pending.id,
        source: source,
      );
      if (!mounted) return;
      _showMessage(_t('Memory changes applied', '记忆变更已应用'));
      await _reload();
    } catch (error) {
      _showMessage('$error');
      await _reload();
    }
  }

  Future<void> _discardPending(StoryMemoryPendingPatch pending) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Discard memory changes?', '丢弃记忆变更？')),
        content: Text(
          _t('The original conversation will not be changed.', '不会修改原始对话内容。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_t('Cancel', '取消')),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Lucide.Trash, size: 18),
            label: Text(_t('Discard', '丢弃')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<StoryMemoryRepository>().discardPendingPatch(
        pending.id,
      );
      await _reload();
    } catch (error) {
      _showMessage('$error');
    }
  }

  StoryMemoryPatchLog? _latestCommittedPatch() {
    final patches = _snapshot?.patches
        .where(
          (patch) =>
              patch.status == 'committed' &&
              (patch.manual ||
                  _snapshot!.checkpoints.any(
                    (checkpoint) =>
                        checkpoint.patchId == patch.id &&
                        checkpoint.status == 'valid',
                  )),
        )
        .toList(growable: false);
    return patches == null || patches.isEmpty ? null : patches.last;
  }

  Future<void> _undoLatest() async {
    final patch = _latestCommittedPatch();
    if (patch == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Undo latest memory update?', '撤销最近一次记忆更新？')),
        content: Text(
          patch.manual
              ? _t(
                  'This restores the story tables to their state before the manual edit.',
                  '这会将故事表格恢复到本次手动编辑之前的状态。',
                )
              : _t(
                  'This restores the story tables to their state before messages ${patch.sourceStartOrder}..${patch.sourceEndOrder}.',
                  '这会将故事表格恢复到消息 ${patch.sourceStartOrder}..${patch.sourceEndOrder} 之前的状态。',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_t('Cancel', '取消')),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Lucide.RotateCcw, size: 18),
            label: Text(_t('Undo', '撤销')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<StoryMemoryRepository>().undoPatch(patch.id);
      if (!mounted) return;
      _showMessage(_t('Memory update undone', '记忆更新已撤销'));
      await _reload();
    } catch (error) {
      _showMessage('$error');
      await _reload();
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Clear story memory?', '清空故事记忆？')),
        content: Text(
          _t(
            'Only this conversation\'s story tables and checkpoints will be removed. Original messages remain unchanged.',
            '只会删除本对话的故事表格和覆盖检查点，原始消息不会改变。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_t('Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_t('Clear', '清空')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<StoryMemoryRepository>().clear(widget.conversationId);
    await _reload();
  }

  Future<void> _add() async {
    final table = StoryMemoryTable.values[_tabs.index];
    final id = const Uuid().v4();
    final seed = <String, dynamic>{
      switch (table) {
        StoryMemoryTable.character => 'characterId',
        StoryMemoryTable.characterState => 'characterId',
        StoryMemoryTable.relationship => 'relationshipId',
        StoryMemoryTable.event => 'eventId',
        StoryMemoryTable.plotSummary => 'summaryId',
      }: id,
      if (table == StoryMemoryTable.character) 'name': '',
      if (table == StoryMemoryTable.character) 'lockedFields': <String>[],
      if (table == StoryMemoryTable.event) 'participants': <String>[],
      if (table == StoryMemoryTable.plotSummary) 'sourceMessageIds': <String>[],
    };
    await _editRow(table: table, id: id, data: seed, isNew: true);
  }

  Future<void> _editRow({
    required StoryMemoryTable table,
    required String id,
    required Map<String, dynamic> data,
    bool isNew = false,
  }) async {
    final controller = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(data),
    );
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isNew ? _t('New row', '新增记录') : _t('Edit row', '编辑记录')),
        content: SizedBox(
          width: 620,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 8,
            maxLines: 16,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              labelText: _t('JSON data', 'JSON 数据'),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_t('Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () {
              try {
                final decoded = jsonDecode(controller.text);
                if (decoded is! Map) throw const FormatException('object');
                Navigator.pop(
                  context,
                  decoded.map((key, value) => MapEntry(key.toString(), value)),
                );
              } catch (_) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(_t('Invalid JSON', 'JSON 格式无效'))),
                );
              }
            },
            child: Text(_t('Save', '保存')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    try {
      await context.read<StoryMemoryRepository>().saveManualRow(
        conversationId: widget.conversationId,
        table: table,
        id: id,
        data: result,
      );
      await _reload();
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _deleteRow(StoryMemoryRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Delete row?', '删除记录？')),
        content: Text(
          _t(
            'This changes only story memory and can be undone from the toolbar.',
            '此操作只修改故事记忆，也可通过顶部撤销按钮恢复。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_t('Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_t('Delete', '删除')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<StoryMemoryRepository>().deleteManualRow(
      conversationId: widget.conversationId,
      table: row.table,
      id: row.id,
    );
    await _reload();
  }

  Future<void> _editLocks(StoryMemoryRow row) async {
    final available = [
      'name',
      'identity',
      'appearance',
      'coreTraits',
      'motivation',
      'background',
    ];
    final current = {
      ...((row.data['lockedFields'] is List)
          ? (row.data['lockedFields'] as List).whereType<String>()
          : const <String>[]),
    };
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_t('Locked character fields', '锁定角色字段')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final field in available)
                  CheckboxListTile(
                    value: current.contains(field),
                    title: Text(field),
                    dense: true,
                    onChanged: (value) => setDialogState(() {
                      if (value == true) {
                        current.add(field);
                      } else {
                        current.remove(field);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_t('Cancel', '取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, current),
              child: Text(_t('Save', '保存')),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final lockedFields = selected.toList()..sort();
    final data = Map<String, dynamic>.from(row.data)
      ..['lockedFields'] = lockedFields;
    await context.read<StoryMemoryRepository>().saveManualRow(
      conversationId: widget.conversationId,
      table: row.table,
      id: row.id,
      data: data,
      sortOrder: row.sortOrder,
    );
    await _reload();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _tableLabel(StoryMemoryTable table) => switch (table) {
    StoryMemoryTable.character => _t('Characters', '角色'),
    StoryMemoryTable.characterState => _t('States', '状态'),
    StoryMemoryTable.relationship => _t('Relations', '关系'),
    StoryMemoryTable.event => _t('Events', '事件'),
    StoryMemoryTable.plotSummary => _t('Plot summaries', '情节摘要'),
  };

  String _rowTitle(StoryMemoryRow row) {
    for (final key in const [
      'name',
      'summary',
      'relationType',
      'location',
      'eventId',
      'summaryId',
    ]) {
      final value = row.data[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return row.id;
  }

  String _rowSubtitle(StoryMemoryRow row) {
    final sourceStart = row.data['sourceStartOrder'];
    final sourceEnd = row.data['sourceEndOrder'];
    final source = sourceStart is int && sourceEnd is int
        ? '  [$sourceStart..$sourceEnd]'
        : '';
    final encoded = jsonEncode(row.data);
    final short = encoded.length > 260
        ? '${encoded.substring(0, 260)}...'
        : encoded;
    return '$short$source';
  }

  List<StoryMemoryRow> _filteredRows(StoryMemoryTable table) {
    final rows = _snapshot?.rowsFor(table) ?? const <StoryMemoryRow>[];
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return rows;
    return [
      for (final row in rows)
        if (row.id.toLowerCase().contains(query) ||
            jsonEncode(row.data).toLowerCase().contains(query))
          row,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(
        title: Text(_t('Story memory', '故事记忆')),
        actions: [
          IconButton(
            tooltip: _t('Organize now', '立即整理'),
            onPressed: _organizing ? null : _organize,
            icon: _organizing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Lucide.Sparkles),
          ),
          IconButton(
            tooltip: _t('Refresh', '刷新'),
            onPressed: _reload,
            icon: const Icon(Lucide.RefreshCw),
          ),
          IconButton(
            tooltip: _t('Undo latest memory update', '撤销最近一次记忆更新'),
            onPressed: _latestCommittedPatch() == null ? null : _undoLatest,
            icon: const Icon(Lucide.RotateCcw),
          ),
          IconButton(
            tooltip: _t('Clear conversation memory', '清空本对话记忆'),
            onPressed: _clear,
            icon: const Icon(Lucide.Trash),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _CoverageBanner(snapshot: snapshot, label: _t),
                _PendingPatches(
                  snapshot: snapshot,
                  label: _t,
                  onConfirm: _confirmPending,
                  onDiscard: _discardPending,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Lucide.Search),
                      hintText: _t('Search story memory', '搜索故事记忆'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                TabBar(
                  controller: _tabs,
                  isScrollable: true,
                  tabs: [
                    for (final table in StoryMemoryTable.values)
                      Tab(text: _tableLabel(table)),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      for (final table in StoryMemoryTable.values)
                        _buildRows(table),
                    ],
                  ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        tooltip: _t('Add row', '新增记录'),
        onPressed: _add,
        child: const Icon(Lucide.Plus),
      ),
    );
  }

  Widget _buildRows(StoryMemoryTable table) {
    final rows = _filteredRows(table);
    if (rows.isEmpty) {
      return Center(child: Text(_t('No records', '暂无记录')));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final row = rows[index];
        final locked =
            row.table == StoryMemoryTable.character &&
            ((row.data['lockedFields'] as List?)?.isNotEmpty ?? false);
        return ListTile(
          title: Text(
            _rowTitle(row),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _rowSubtitle(row),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          leading: Icon(locked ? Lucide.Lock : Lucide.FileText, size: 20),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (row.table == StoryMemoryTable.character)
                IconButton(
                  tooltip: _t('Lock fields', '锁定字段'),
                  onPressed: () => _editLocks(row),
                  icon: Icon(locked ? Lucide.Lock : Lucide.LockOpen),
                ),
              IconButton(
                tooltip: _t('Edit', '编辑'),
                onPressed: () =>
                    _editRow(table: row.table, id: row.id, data: row.data),
                icon: const Icon(Lucide.Edit),
              ),
              IconButton(
                tooltip: _t('Delete', '删除'),
                onPressed: () => _deleteRow(row),
                icon: const Icon(Lucide.Trash),
              ),
            ],
          ),
        );
      },
    );
  }
}

final class _PendingPatches extends StatelessWidget {
  const _PendingPatches({
    required this.snapshot,
    required this.label,
    required this.onConfirm,
    required this.onDiscard,
  });

  final StoryMemorySnapshot? snapshot;
  final String Function(String en, String zh) label;
  final Future<void> Function(StoryMemoryPendingPatch pending) onConfirm;
  final Future<void> Function(StoryMemoryPendingPatch pending) onDiscard;

  @override
  Widget build(BuildContext context) {
    final pending =
        snapshot?.pendingPatches
            .where((patch) => patch.isPending)
            .toList(growable: false) ??
        const <StoryMemoryPendingPatch>[];
    if (pending.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label('Pending memory changes', '待审核的记忆变更'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          for (final patch in pending)
            Card(
              margin: const EdgeInsets.only(top: 6),
              child: ListTile(
                dense: true,
                title: Text(
                  label(
                    'Messages ${patch.patch.sourceStartOrder}..${patch.patch.sourceEndOrder}',
                    '消息 ${patch.patch.sourceStartOrder}..${patch.patch.sourceEndOrder}',
                  ),
                ),
                subtitle: Text(
                  label(
                    '${patch.patch.operations.length} operations awaiting review',
                    '${patch.patch.operations.length} 项变更等待审核',
                  ),
                ),
                trailing: Wrap(
                  spacing: 0,
                  children: [
                    IconButton(
                      tooltip: label('Apply changes', '应用变更'),
                      onPressed: () => onConfirm(patch),
                      icon: const Icon(Lucide.Check),
                    ),
                    IconButton(
                      tooltip: label('Discard changes', '丢弃变更'),
                      onPressed: () => onDiscard(patch),
                      icon: const Icon(Lucide.Trash),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final class _CoverageBanner extends StatelessWidget {
  const _CoverageBanner({required this.snapshot, required this.label});

  final StoryMemorySnapshot? snapshot;
  final String Function(String en, String zh) label;

  @override
  Widget build(BuildContext context) {
    final checkpoints =
        snapshot?.checkpoints ?? const <StoryMemoryCheckpoint>[];
    final valid = checkpoints
        .where((checkpoint) => checkpoint.isValid)
        .toList();
    final stale = checkpoints.where((checkpoint) => !checkpoint.isValid).length;
    final text = valid.isEmpty
        ? label('No verified coverage yet', '尚无已验证覆盖范围')
        : label(
            'Covered through message order ${valid.last.endOrder}',
            '已覆盖至消息序号 ${valid.last.endOrder}',
          );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          const Icon(Lucide.ShieldCheck, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
          if (stale > 0)
            Text(
              label('$stale stale', '$stale 条已失效'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
