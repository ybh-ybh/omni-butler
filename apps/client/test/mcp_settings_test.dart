import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/core/auth/auth_models.dart';
import 'package:omni_butler/core/auth/auth_providers.dart';
import 'package:omni_butler/core/auth/auth_repository.dart';
import 'package:omni_butler/features/settings/data/mcp_repository.dart';
import 'package:omni_butler/features/settings/presentation/mcp_settings_section.dart';
import 'package:omni_butler/features/settings/presentation/sync_conflicts_section.dart';
import 'package:omni_butler/shared/ui/omni_switch.dart';
import 'package:omni_butler/shared/ui/omni_button.dart';

/// 只模拟认证传输边界，不调用实际后端或安全存储。
class _Auth extends Fake implements AuthRepository {
  /// 当前服务器代次。
  int generation = 1;

  /// 测试捕获的管理请求，不包含真实令牌。
  final List<({String method, String path, Object? data})> calls = [];

  /// 可注入延迟、冲突或网络异常。
  Future<Map<String, dynamic>> Function(String path)? handler;

  /// 返回当前服务器代次。
  @override
  int get sessionGeneration => generation;

  /// 请求前后均校验代次，模拟生产认证门禁。
  @override
  Future<Response<T>> authorizedRequestForGeneration<T>(
    int generation,
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    ResponseType? responseType,
    Duration? receiveTimeout,
    bool preserveTransportErrors = false,
    CancelToken? cancelToken,
  }) async {
    if (generation != this.generation) throw const ApiFailure('同步会话已变更');
    calls.add((method: method, path: path, data: data));
    // 受控响应仅在相同服务器代次返回。
    final Map<String, dynamic> value = await handler?.call(path) ?? _snapshot();
    if (generation != this.generation) throw const ApiFailure('同步会话已变更');
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      data: value as T,
    );
  }
}

/// 不访问平台存储的固定认证控制器。
class _Controller extends AuthController {
  /// 是否连接服务器。
  final bool connected;

  /// 创建测试认证状态。
  _Controller({this.connected = true});

  /// 返回固定会话，离线时不给管理API权限。
  @override
  Future<SyncSession?> build() async => connected
      ? const SyncSession(
          identity: SyncIdentity(id: 'owner'),
          apiBaseUrl: 'https://example.test/api',
          isOffline: false,
        )
      : null;
}

/// 无密钥、无业务正文的安全列表快照。
Map<String, dynamic> _snapshot({
  bool action = false,
  List<Map<String, dynamic>> connections = const <Map<String, dynamic>>[],
}) => <String, dynamic>{
  'connections': connections,
  'actions': action
      ? <Object>[
          <String, dynamic>{
            'id': 'action-1',
            'status': 'pending',
            'createdAt': '2026-10-20T01:00:00Z',
            'preview': <String, dynamic>{'affectedRecords': 1},
          },
        ]
      : <Object>[],
};

/// 合成连接只包含列表允许公开的字段。
Map<String, dynamic> _connection(
  String id,
  String name, {
  bool revoked = false,
}) => <String, dynamic>{
  'id': id,
  'name': name,
  'revokedAt': revoked ? '2026-10-23T01:00:00Z' : null,
  'readModules': mcpModuleLabels.keys.toList(),
  'writeModules': <String>['notes'],
  'expiresAt': null,
  'timeZone': 'Asia/Shanghai',
};

/// 冻结的完整操作预览。
Map<String, dynamic> _preview() => <String, dynamic>{
  'id': 'action-1',
  'status': 'pending',
  'expiresAt': '2026-10-20T01:10:00Z',
  'preview': <String, dynamic>{
    'affectedRecords': 1,
    'steps': <Object>[
      <String, dynamic>{
        'description': '修改已选物品的位置，不创建额外物品。',
        'input': <String, dynamic>{'id': 'chosen-item-id', 'location': '客厅'},
      },
    ],
    'changes': <Object>[
      <String, dynamic>{
        'newRecord': false,
        'label': '书籍',
        'before': <String, dynamic>{'location': '书房'},
        'after': <String, dynamic>{'location': '客厅'},
      },
    ],
  },
};

/// 真实布局与模态窗口，分别验证Windows和Android大字号。
Future<void> _pump(
  WidgetTester tester,
  _Auth auth, {
  bool connected = true,
  double width = 1000,
  double scale = 1,
  TargetPlatform platform = TargetPlatform.windows,
  Widget section = const McpSettingsSection(),
}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        authControllerProvider.overrideWith(
          () => _Controller(connected: connected),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.build(brightness: Brightness.light)
            .copyWith(platform: platform),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(padding: const EdgeInsets.all(16), child: section),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 管理和审批界面与认证代次保护的定向回归。
void main() {
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('${platform.name} 连接卡片隐藏已撤销项，卡头及行内操作靠右且大字号不溢出', (
      WidgetTester tester,
    ) async {
      // Windows核对水平几何，Android覆盖最窄窗口和双倍字号。
      final bool desktop = platform == TargetPlatform.windows;
      // 后端历史依然含撤销记录，页面只展示未撤销连接。
      final _Auth auth = _Auth()
        ..handler = (String path) async => _snapshot(
          connections: <Map<String, dynamic>>[
            _connection('active', '日常 Codex'),
            _connection('revoked', '旧 Codex', revoked: true),
          ],
        );
      await _pump(
        tester,
        auth,
        platform: platform,
        width: desktop ? 1000 : 320,
        scale: desktop ? 1 : 2,
      );
      // 卡片包含标题和连接条目，已撤销项及原长说明均不占位。
      final Finder card = find.byKey(
        const ValueKey<String>('mcp-connections-card'),
      );
      final Finder row = find.byKey(
        const ValueKey<String>('mcp-connection-active'),
      );
      final Finder create = find.widgetWithText(OmniButton, '新增连接');
      final Finder refresh = find.widgetWithText(OmniButton, '刷新状态');
      final Finder revoke = find.widgetWithText(OmniButton, '撤销连接');
      expect(find.descendant(of: card, matching: row), findsOneWidget);
      expect(find.descendant(of: card, matching: create), findsOneWidget);
      expect(find.text('旧 Codex'), findsNothing);
      expect(find.textContaining('默认只读，按模块授权。'), findsNothing);
      expect(revoke, findsOneWidget);
      // 单行或换行后，操作始终贴齐卡片右侧内容边界。
      expect(
        tester.getRect(refresh).right,
        closeTo(tester.getRect(row).right, .01),
      );
      expect(
        tester.getRect(revoke).right,
        closeTo(tester.getRect(row).right, .01),
      );
      expect(
        tester.getRect(revoke).left,
        greaterThan(tester.getRect(find.text('日常 Codex')).right),
      );
      if (desktop) {
        expect(
          tester.getRect(create).left,
          greaterThan(tester.getRect(find.text('MCP 连接')).right),
        );
        expect(
          tester.getCenter(create).dy,
          closeTo(tester.getCenter(refresh).dy, .01),
        );
      }
      expect(tester.takeException(), isNull);
      // 刷新仍请求当前列表，不重放新增或撤销。
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(
        auth.calls.where((call) => call.method == 'GET').length,
        greaterThan(1),
      );
      expect(auth.calls.where((call) => call.method == 'POST'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${platform.name} 操作记录卡片按时间只显示最近30条，查看按钮靠右且绑定对应操作', (
      WidgetTester tester,
    ) async {
      // Windows核对同行居中，Android核对320dp双倍字号的换行布局。
      final bool desktop = platform == TargetPlatform.windows;
      // 使用完整UUID和跨状态记录，避免短测试身份掩盖窄屏换行问题。
      final List<Map<String, dynamic>> history = List.generate(
        35,
        (int index) => <String, dynamic>{
          'id': '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
          'status': index < 10 ? 'pending' : 'succeeded',
          'createdAt': DateTime.utc(2026, 10, 23, 0, index).toIso8601String(),
          'preview': <String, dynamic>{'affectedRecords': 1},
        },
      );
      // 第30条仍可查看详情，裁掉的旧记录不能占用展示名额。
      final String lastId = history[5]['id'] as String;
      // 模拟真实接口把较早待执行记录放在历史记录之前的分组顺序。
      final _Auth auth = _Auth()
        ..handler = (String path) async => path.endsWith('/actions/$lastId')
            ? <String, dynamic>{..._preview(), 'id': lastId}
            : <String, dynamic>{
                ..._snapshot(),
                'actions': <Map<String, dynamic>>[
                  ...history.take(10),
                  ...history.skip(10).toList().reversed,
                ],
              };
      await _pump(
        tester,
        auth,
        platform: platform,
        width: desktop ? 1000 : 320,
        scale: desktop ? 1 : 2,
      );
      // 所有记录与标题都包含在同一张操作记录卡片中。
      final Finder card = find.byKey(
        const ValueKey<String>('mcp-actions-card'),
      );
      // 使用行身份读取真实渲染顺序，不能只检查列表长度。
      final Finder rows = find.descendant(
        of: card,
        matching: find.byWidgetPredicate(
          (Widget widget) =>
              widget is Padding &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'mcp-action-row-',
              ),
        ),
      );
      expect(
        find.descendant(of: card, matching: find.text('操作记录')),
        findsOneWidget,
      );
      expect(rows, findsNWidgets(30));
      expect(
        tester.widgetList<Padding>(rows).map((Padding row) => row.key),
        orderedEquals(
          history.reversed
              .take(30)
              .map(
                (Map<String, dynamic> action) =>
                    ValueKey<String>('mcp-action-row-${action['id']}'),
              ),
        ),
      );
      // 30条记录只有29条分隔线，逐一核对横向铺满和上下位置。
      final Finder dividers = find.descendant(
        of: card,
        matching: find.byType(Divider),
      );
      expect(dividers, findsNWidgets(29));
      for (int index = 0; index < 29; index++) {
        // 分隔线只能出现在前后两条记录之间。
        final Rect divider = tester.getRect(dividers.at(index));
        // 上一条记录的布局边界包含其原有留白。
        final Rect previous = tester.getRect(rows.at(index));
        // 下一条记录紧接细线，不能引入额外空白行。
        final Rect next = tester.getRect(rows.at(index + 1));
        expect(divider.left, closeTo(previous.left, .01));
        expect(divider.right, closeTo(previous.right, .01));
        expect(divider.top, closeTo(previous.bottom, .01));
        expect(divider.bottom, closeTo(next.top, .01));
        expect(divider.height, 1);
      }
      // 最新一条的按钮贴齐内容右侧；大字号下换到摘要下方。
      final Finder firstRow = find.byKey(
        ValueKey<String>('mcp-action-row-${history.last['id']}'),
      );
      // 每条按钮具有自己的操作身份。
      final Finder firstButton = find.byKey(
        ValueKey<String>('mcp-action-review-${history.last['id']}'),
      );
      expect(
        tester.getRect(firstButton).right,
        closeTo(tester.getRect(firstRow).right, .01),
      );
      if (desktop) {
        expect(
          tester.getCenter(firstButton).dy,
          closeTo(tester.getCenter(firstRow).dy, .01),
        );
      } else {
        expect(
          tester.getRect(firstButton).top,
          greaterThan(
            tester
                .getRect(
                  find.descendant(
                    of: firstRow,
                    matching: find.textContaining('影响'),
                  ),
                )
                .bottom,
          ),
        );
      }
      expect(tester.takeException(), isNull);
      // 滚动到最后一条并打开详情，验证排序和截断未串用其他操作ID。
      final Finder lastButton = find.byKey(
        ValueKey<String>('mcp-action-review-$lastId'),
      );
      await tester.ensureVisible(lastButton);
      await tester.tap(lastButton);
      await tester.pumpAndSettle();
      expect(auth.calls.last.path, '/mcp-management/actions/$lastId');
      expect(find.text('MCP 操作详情'), findsOneWidget);
      expect(auth.calls.every((call) => call.method == 'GET'), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('空操作记录也在卡片内显示说明', (WidgetTester tester) async {
    await _pump(tester, _Auth());
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mcp-actions-card')),
        matching: find.text('暂无 MCP 操作。使用 Codex 操作后，可刷新查看记录与结果。'),
      ),
      findsOneWidget,
    );
    expect(find.text('查看操作'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mcp-actions-card')),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );
  });

  testWidgets('行内撤销绑定对应连接，成功刷新后隐藏该项', (WidgetTester tester) async {
    // 模拟撤销后的同一列表仍保留服务端审计记录。
    bool revoked = false;
    // 按连接身份验证操作请求，避免列表过滤后索引错位。
    final _Auth auth = _Auth()
      ..handler = (String path) async {
        if (path.endsWith('/connections/active/revoke')) revoked = true;
        return _snapshot(
          connections: <Map<String, dynamic>>[
            _connection('old', '历史连接', revoked: true),
            _connection('active', '当前连接', revoked: revoked),
            _connection('other', '另一连接'),
          ],
        );
      };
    await _pump(tester, auth);
    // 确认窗口仅来自撤销，不影响助手开关的直接保存。
    final Finder row = find.byKey(
      const ValueKey<String>('mcp-connection-active'),
    );
    await tester.tap(
      find.descendant(
        of: row,
        matching: find.widgetWithText(OmniButton, '撤销连接'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('撤销 当前连接？'), findsOneWidget);
    await tester.tap(find.widgetWithText(OmniButton, '撤销连接').last);
    await tester.pumpAndSettle();
    expect(
      auth.calls.where((call) => call.method == 'POST').single.path,
      '/mcp-management/connections/active/revoke',
    );
    expect(find.text('当前连接'), findsNothing);
    expect(find.text('历史连接'), findsNothing);
    expect(find.text('另一连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未连接时说明连接后端，不读取或创建空配置', (WidgetTester tester) async {
    // 未认证状态下不得发管理请求。
    final _Auth auth = _Auth();
    await _pump(tester, auth, connected: false);
    expect(find.textContaining('连接后端后'), findsOneWidget);
    expect(auth.calls, isEmpty);
  });

  testWidgets('连接默认只读，创建令牌只显示一次，列表不持久保存', (WidgetTester tester) async {
    // 只在创建响应返回测试明文，不在列表出现。
    final _Auth auth = _Auth()
      ..handler = (String path) async => path.endsWith('/connections')
          ? <String, dynamic>{'token': 'omni_mcp_test-only-secret'}
          : _snapshot();
    await _pump(tester, auth);
    await tester.tap(find.text('新增连接'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OmniSwitchListTile>(
            find.widgetWithText(OmniSwitchListTile, '允许修改笔记数据'),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.text('创建连接'));
    await tester.pumpAndSettle();
    expect(find.text('omni_mcp_test-only-secret'), findsOneWidget);
    // 请求使用管理路径和默认空写范围，不上传MCP令牌或owner。
    final Map input =
        auth.calls
                .firstWhere(
                  (({String method, String path, Object? data}) call) =>
                      call.path.endsWith('/connections'),
                )
                .data!
            as Map;
    expect(input['writeModules'], isEmpty);
    expect(input['ttlDays'], 30);
    expect(input.containsKey('userId'), isFalse);
    await tester.tap(find.text('已保存'));
    await tester.pumpAndSettle();
    expect(find.text('omni_mcp_test-only-secret'), findsNothing);
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('$platform 新增连接可选择永久并以空期限提交，列表展示永久', (
      WidgetTester tester,
    ) async {
      // 真实表单控制请求；仅网络返回值按创建前后切换。
      bool created = false;
      // 不持久保存一次性令牌的安全列表。
      final _Auth auth = _Auth()
        ..handler = (String path) async {
          if (path.endsWith('/connections')) {
            created = true;
            return <String, dynamic>{'token': 'omni_mcp_permanent-test-only'};
          }
          return <String, dynamic>{
            ..._snapshot(),
            'connections': <Object>[
              if (created)
                <String, dynamic>{
                  'id': 'permanent',
                  'name': 'Codex',
                  'readModules': <String>['quotes'],
                  'writeModules': <String>[],
                  'expiresAt': null,
                },
            ],
          };
        };
      await _pump(
        tester,
        auth,
        platform: platform,
        width: platform == TargetPlatform.android ? 390 : 1000,
      );
      await tester.tap(find.text('新增连接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 天'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('永久').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建连接'));
      await tester.pumpAndSettle();
      // 显式null与省略默认30天区分，不能把0天当成过期连接发送。
      final Map input =
          auth.calls
                  .firstWhere((call) => call.path.endsWith('/connections'))
                  .data!
              as Map;
      expect(input.containsKey('ttlDays'), isTrue);
      expect(input['ttlDays'], isNull);
      await tester.tap(find.text('已保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('到期：永久'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('勾选写权限表示直接修改，并自动包含该模块读取权限', (WidgetTester tester) async {
    // 表单实际选择决定权限，没有额外的后台默认写范围。
    final _Auth auth = _Auth()
      ..handler = (String path) async => path.endsWith('/connections')
          ? <String, dynamic>{'token': 'omni_mcp_scoped-test'}
          : _snapshot();
    await _pump(tester, auth);
    await tester.tap(find.text('新增连接'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('读取笔记'));
    await tester.tap(find.text('读取笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许修改笔记数据'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OmniSwitchListTile>(
            find.widgetWithText(OmniSwitchListTile, '读取笔记'),
          )
          .value,
      isTrue,
    );
    await tester.tap(find.text('创建连接'));
    await tester.pumpAndSettle();
    // 模块权限请求不包含批准人、confirmed或新的审批模式开关。
    final Map input =
        auth.calls
                .firstWhere((call) => call.path.endsWith('/connections'))
                .data!
            as Map;
    expect(input['writeModules'], <String>['notes']);
    expect(input['readModules'], contains('notes'));
    expect(input.containsKey('confirmed'), isFalse);
  });

  for (final String status in <String>[
    'pending',
    'approved',
    'cancelled',
    'succeeded',
    'conflict',
  ]) {
    testWidgets('操作$status仅展示完整详情和真实结果，没有审批或提交入口', (WidgetTester tester) async {
      // 列表摘要不含完整差异，必须实际读取操作详情。
      final _Auth auth = _Auth()
        ..handler = (String path) async => path.endsWith('/actions/action-1')
            ? <String, dynamic>{
                ..._preview(),
                'status': status,
                if (status == 'succeeded' || status == 'conflict')
                  'result': <String, dynamic>{
                    'syncStatus': status == 'conflict'
                        ? '冲突候选已保存，正式正文未采用'
                        : '服务器已保存，客户端下行状态未知',
                    'serverSavedAt': '2026-10-20T01:01:00Z',
                    'values': <Object>[
                      <String, dynamic>{
                        'id': 'actual-record-id',
                        'name': '实际结果',
                      },
                    ],
                  },
              }
            : _snapshot(action: true);
      await _pump(tester, auth);
      expect(find.text('操作记录'), findsOneWidget);
      // 单条记录不需要分隔线，避免误画卡片首尾边框。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('mcp-actions-card')),
          matching: find.byType(Divider),
        ),
        findsNothing,
      );
      await tester.tap(find.text('查看操作'));
      await tester.pumpAndSettle();
      expect(find.text('MCP 操作详情'), findsOneWidget);
      expect(find.textContaining('书房 → 客厅'), findsOneWidget);
      expect(find.text('记录身份：chosen-item-id'), findsOneWidget);
      expect(find.text('批准操作'), findsNothing);
      expect(find.text('取消操作'), findsNothing);
      if (status == 'approved') {
        expect(find.text('旧流程操作，请在 Codex 重新发起'), findsOneWidget);
      }
      if (status == 'cancelled') expect(find.text('已取消'), findsOneWidget);
      if (status == 'succeeded' || status == 'conflict') {
        expect(find.textContaining('记录身份：actual-record-id'), findsOneWidget);
      }
      if (status == 'conflict') {
        expect(find.text('冲突候选已保存，正式正文未采用'), findsOneWidget);
      }
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(auth.calls.every((call) => call.method == 'GET'), isTrue);
    });
  }

  testWidgets('换服后迟到完整操作详情不弹出、不提交决策', (WidgetTester tester) async {
    // 可控制的旧服务器请求响应。
    final Completer<Map<String, dynamic>> delayed =
        Completer<Map<String, dynamic>>();
    // 旧服务器完整预览等待用户已切服后才返回。
    final _Auth auth = _Auth()
      ..handler = (String path) async => path.endsWith('/actions/action-1')
          ? delayed.future
          : _snapshot(action: true);
    await _pump(tester, auth);
    await tester.tap(find.text('查看操作'));
    await tester.pump();
    auth.generation++;
    delayed.complete(_preview());
    await tester.pumpAndSettle();
    expect(find.text('批准操作'), findsNothing);
    expect(
      auth.calls.any(
        (({String method, String path, Object? data}) call) =>
            call.path.endsWith('/decision'),
      ),
      isFalse,
    );
  });

  testWidgets('Android窄屏双倍字号可查看完整操作，无布局溢出', (WidgetTester tester) async {
    // 320dp和大字号覆盖长按钮及差异换行。
    final _Auth auth = _Auth()
      ..handler = (String path) async => path.endsWith('/actions/action-1')
          ? _preview()
          : _snapshot(action: true);
    await _pump(
      tester,
      auth,
      width: 320,
      scale: 2,
      platform: TargetPlatform.android,
    );
    await tester.ensureVisible(find.text('查看操作'));
    await tester.tap(find.text('查看操作'));
    await tester.pumpAndSettle();
    expect(find.text('MCP 操作详情'), findsOneWidget);
    expect(find.text('批准操作'), findsNothing);
    expect(find.text('取消操作'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('仓储只使用固定代次；网络错误不泄露请求头或专用令牌', () async {
    // 模拟Dio包含敏感Authorization的连接失败。
    final _Auth auth = _Auth()
      ..handler = (String path) async => throw DioException(
        requestOptions: RequestOptions(
          path: path,
          headers: <String, dynamic>{'Authorization': 'secret-do-not-show'},
        ),
      );
    // 仓储持有当前服务器身份，不能切服后复用。
    final McpRepository repository = McpRepository(auth);
    await expectLater(
      repository.load(),
      throwsA(
        isA<ApiFailure>().having(
          (ApiFailure value) => value.message,
          '安全消息',
          isNot(contains('secret-do-not-show')),
        ),
      ),
    );
    auth.generation++;
    await expectLater(repository.load(), throwsA(isA<ApiFailure>()));
  });

  testWidgets('同步冲突展示完整本机意图和服务器差异，稍后处理不提交，明确采用服务器才决策', (
    WidgetTester tester,
  ) async {
    // 待决摘要及完整事实来自不同请求，不能凭摘要直接处理。
    final _Auth auth = _Auth()
      ..handler = (String path) async {
        if (path.endsWith('/resolve')) {
          return <String, dynamic>{'message': '已选择服务器，原设备会继续重试核实'};
        }
        if (path.endsWith('/conflict-1')) {
          return <String, dynamic>{
            'status': 'pending',
            'baselineHash': 'server-facts-hash',
            'currentRecords': <Object>[
              <String, dynamic>{
                'table': 'quotes',
                'id': 'quote-1',
                'data': <String, dynamic>{'content': 'MCP服务器值'},
              },
            ],
            'operations': <Object>[
              <String, dynamic>{
                'op': 'PATCH',
                'table': 'quotes',
                'id': 'quote-1',
                'data': <String, dynamic>{'content': '原始本机意图'},
              },
            ],
          };
        }
        return <String, dynamic>{
          'items': <Object>[
            <String, dynamic>{
              'id': 'conflict-1',
              'operationCount': 1,
              'createdAt': '2026-10-20',
            },
          ],
        };
      };
    await _pump(tester, auth, section: const SyncConflictsSection());
    await tester.tap(find.text('核对冲突'));
    await tester.pumpAndSettle();
    expect(find.textContaining('MCP服务器值 → 原始本机意图'), findsOneWidget);
    await tester.tap(find.text('稍后处理'));
    await tester.pumpAndSettle();
    expect(
      auth.calls.any(
        (({String method, String path, Object? data}) call) =>
            call.path.endsWith('/resolve'),
      ),
      isFalse,
    );
    await tester.tap(find.text('核对冲突'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('采用服务器'));
    await tester.pumpAndSettle();
    // 确认摘要与本次人工请求身份固定，不上传改写后的原业务数据。
    final Map decision =
        auth.calls
                .firstWhere(
                  (({String method, String path, Object? data}) call) =>
                      call.path.endsWith('/resolve'),
                )
                .data!
            as Map;
    expect(decision['decision'], 'server');
    expect(decision['baselineHash'], 'server-facts-hash');
    expect(decision['requestId'], isA<String>());
    expect(decision.containsKey('operations'), isFalse);
    expect(find.text('已选择服务器，原设备会继续重试核实'), findsOneWidget);
  });

  testWidgets('同步删除预览展示原队列之外的关联事实，稍后处理不提交', (WidgetTester tester) async {
    // 服务器当前聚合多了旧离线队列未包含的配件。
    final _Auth auth = _Auth()
      ..handler = (String path) async {
        if (path.endsWith('/cascade-1')) {
          return <String, dynamic>{
            'baselineHash': 'aggregate-facts',
            'currentRecords': <Object>[
              <String, dynamic>{
                'table': 'inventory_items',
                'id': 'parent',
                'data': <String, dynamic>{'name': '父物品'},
              },
              <String, dynamic>{
                'table': 'inventory_items',
                'id': 'child',
                'data': <String, dynamic>{
                  'name': '后来MCP配件',
                  'parent_item_id': 'parent',
                },
              },
            ],
            'operations': <Object>[
              <String, dynamic>{
                'op': 'DELETE',
                'table': 'inventory_items',
                'id': 'parent',
              },
            ],
          };
        }
        return <String, dynamic>{
          'items': <Object>[
            <String, dynamic>{
              'id': 'cascade-1',
              'operationCount': 1,
              'createdAt': '2026-10-20',
            },
          ],
        };
      };
    await _pump(tester, auth, section: const SyncConflictsSection());
    await tester.tap(find.text('核对冲突'));
    await tester.pumpAndSettle();
    expect(find.textContaining('后来MCP配件'), findsWidgets);
    expect(find.textContaining('父记录删除可能使此记录删除或失效'), findsOneWidget);
    expect(find.textContaining('父物品 → 未设置'), findsOneWidget);
    await tester.tap(find.text('稍后处理'));
    await tester.pumpAndSettle();
    expect(auth.calls.where((call) => call.method == 'POST'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同步冲突读取失败不能显示没有冲突，Android大字号可完整展示', (WidgetTester tester) async {
    // 无效旧版本响应必须保留错误，而不是编造空集合。
    final _Auth auth = _Auth()
      ..handler = (String path) async => <String, dynamic>{};
    await _pump(
      tester,
      auth,
      width: 320,
      scale: 2,
      platform: TargetPlatform.android,
      section: const SyncConflictsSection(),
    );
    expect(find.textContaining('服务器未返回有效同步冲突列表'), findsOneWidget);
    expect(find.text('没有待处理的同步冲突。'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
