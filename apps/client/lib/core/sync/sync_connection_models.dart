/// 用户明确选择的数据来源策略。
enum SyncConnectionStrategy { mergeInitial, replaceServer, replaceLocal }

/// 经过密钥认证的连接预览；数量只用于确认，执行时重新获取本机快照。
class SyncConnectionPreview {
  /// 创建双方数据预览。
  const SyncConnectionPreview({
    required this.serverAddress,
    required this.ownerId,
    required this.localOwnerId,
    required this.localCounts,
    required this.remoteCounts,
    required this.localDeletedCount,
    required this.remoteDeletedCount,
    required this.queuedOperations,
    required this.maxOperations,
    required this.maxBytes,
    this.sourceAddress,
  });

  /// 用户输入的目标地址，不含 API 路径。
  final String serverAddress;

  /// 目标数据源身份。
  final String ownerId;

  /// 本机来源身份，空值才是首次接入。
  final String? localOwnerId;

  /// 本机来源地址（历史版本可能未保存）。
  final String? sourceAddress;

  /// 本机各表数量。
  final Map<String, int> localCounts;

  /// 服务器各表数量。
  final Map<String, int> remoteCounts;

  /// 本机回收站记录数量。
  final int localDeletedCount;

  /// 服务端回收站记录数量。
  final int remoteDeletedCount;

  /// 当前待上传操作数量。
  final int queuedOperations;

  /// 目标支持的最大操作数量。
  final int maxOperations;

  /// 目标支持的最大请求字节数。
  final int maxBytes;

  /// 是否可继续原数据源的增量同步。
  bool get isReconnect => localOwnerId == ownerId;

  /// 本机记录总数。
  int get localTotal => localCounts.values.fold(0, (int sum, int n) => sum + n);

  /// 服务端记录总数。
  int get remoteTotal =>
      remoteCounts.values.fold(0, (int sum, int n) => sum + n);
}

/// 用于根应用和所有窗口共享的迁移状态。
class SyncConnectionState {
  /// 创建连接状态。
  const SyncConnectionState({
    this.generation = 0,
    this.maintenance = false,
    this.busy = false,
    this.message = '',
    this.error,
    this.canCancel = false,
  });

  /// 活动数据库和会话切换代次，供依赖注入重新绑定。
  final int generation;

  /// 是否禁止当前数据集业务写入。
  final bool maintenance;

  /// 是否有迁移操作在执行。
  final bool busy;

  /// 当前步骤的可读说明。
  final String message;

  /// 当前失败或需要继续操作的说明。
  final String? error;

  /// 尚未提交远端时允许取消。
  final bool canCancel;
}
