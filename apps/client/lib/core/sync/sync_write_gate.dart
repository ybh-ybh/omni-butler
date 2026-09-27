import 'dart:async';

import 'package:drift/drift.dart';

/// 数据源迁移期间旧仓储不可继续写入。
class SyncWritesFrozen implements Exception {
  /// 创建维护状态异常。
  const SyncWritesFrozen();

  /// 返回可供界面展示的维护说明。
  @override
  String toString() => '正在迁移同步数据，请等待迁移完成后再修改。';
}

/// 在共享 Drift 执行器入口冻结写入，覆盖已被业务仓储捕获的数据库引用。
class SyncWriteGate extends QueryInterceptor {
  /// 已经禁止新写入。
  bool _frozen = false;

  /// 已准入且尚未完成的独立操作数量。
  int _operations = 0;

  /// 已准入事务；冻结时让这些事务完整提交或回滚。
  final Set<TransactionExecutor> _transactions = <TransactionExecutor>{};

  /// 当前冻结等待者，在全部准入操作结束后完成。
  Completer<void>? _drained;

  /// 当前是否处于维护状态。
  bool get isFrozen => _frozen;

  /// 先同步关闭准入，再等待已经开始的写操作和事务结束。
  Future<void> freeze() {
    _frozen = true;
    if (_operations == 0 && _transactions.isEmpty) {
      return Future<void>.value();
    }
    return (_drained ??= Completer<void>()).future;
  }

  /// 仅供迁移取消或失败恢复原库时重新开放写入。
  void resume() {
    if (_operations != 0 || _transactions.isNotEmpty) {
      throw StateError('必须等待冻结完成后才能恢复写入');
    }
    _frozen = false;
    _drained = null;
  }

  /// 拒绝冻结之后出现的新写入，已有事务可以排空。
  void _check(QueryExecutor executor) {
    if (_frozen && !_transactions.contains(executor)) {
      throw const SyncWritesFrozen();
    }
  }

  /// 在所有已准入操作结束时唤醒快照导出。
  void _completeDrain() {
    if (_operations == 0 &&
        _transactions.isEmpty &&
        _drained != null &&
        !_drained!.isCompleted) {
      _drained!.complete();
    }
  }

  /// 跟踪独立写操作，包括使用 RETURNING 返回结果的修改。
  Future<T> _run<T>(QueryExecutor executor, Future<T> Function() action) async {
    _check(executor);
    _operations += 1;
    try {
      return await action();
    } finally {
      _operations -= 1;
      _completeDrain();
    }
  }

  /// 跟踪整段事务，而不是仅等待其中最后一条 SQL。
  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    _check(parent);
    // 事务对象在 Drift 调用 ensureOpen 前就已经获得准入。
    final TransactionExecutor transaction = parent.beginTransaction();
    _transactions.add(transaction);
    return transaction;
  }

  /// 事务打开失败时 Drift 尚未进入回滚区，主动释放准入计数。
  @override
  Future<bool> ensureOpen(
    QueryExecutor executor,
    QueryExecutorUser user,
  ) async {
    try {
      return await executor.ensureOpen(user);
    } on Object {
      _transactions.remove(executor);
      _completeDrain();
      rethrow;
    }
  }

  /// 提交完成后释放迁移排空等待。
  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    // 提交失败时 Drift 还会回滚，不能提前唤醒冻结等待者。
    await inner.send();
    _transactions.remove(inner);
    _completeDrain();
  }

  /// 回滚完成后释放迁移排空等待。
  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) async {
    try {
      await inner.rollback();
    } finally {
      _transactions.remove(inner);
      _completeDrain();
    }
  }

  /// 插入由共享准入控制。
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run(executor, () => executor.runInsert(statement, args));

  /// 更新由共享准入控制。
  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run(executor, () => executor.runUpdate(statement, args));

  /// 删除由共享准入控制。
  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run(executor, () => executor.runDelete(statement, args));

  /// 自定义语句可能写入，因此统一经过写门禁。
  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _run(executor, () => executor.runCustom(statement, args));

  /// 批量写入也须与普通业务写入遵守同一门禁。
  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) => _run(executor, () => executor.runBatched(statements));

  /// SELECT 保持可读；INSERT/UPDATE RETURNING 等查询仍经过写门禁。
  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (RegExp(r'^\s*SELECT\b', caseSensitive: false).hasMatch(statement)) {
      return executor.runSelect(statement, args);
    }
    return _run(executor, () => executor.runSelect(statement, args));
  }
}
