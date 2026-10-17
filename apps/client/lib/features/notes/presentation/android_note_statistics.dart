part of 'android_notes_view.dart';

/// 安卓统计独立呈现，仍使用共享的正式数据聚合。
class _AndroidNoteStatistics extends ConsumerStatefulWidget {
  /// 打开时的数据源，选日不能穿过换库。
  final AppDatabase source;

  /// 创建月历与年度图表。
  const _AndroidNoteStatistics({required this.source});

  /// 两个分页拥有独立滚动状态。
  @override
  ConsumerState<_AndroidNoteStatistics> createState() =>
      _AndroidNoteStatisticsState();
}

/// 月年切换与横向分页使用同一选择状态。
class _AndroidNoteStatisticsState
    extends ConsumerState<_AndroidNoteStatistics> {
  /// 实际横向分页位置支持连续反向操作。
  final PageController _pages = PageController();

  /// 月历独立滚动位置。
  final ScrollController _months = ScrollController();

  /// 年度指标独立滚动位置。
  final ScrollController _annual = ScrollController();

  /// 当前月或年分段。
  int _tab = 0;

  /// 当前有记录年份。
  int? _year;

  /// 换年份时替换缓存桶，同年份月年切换仍保留两个滚动位置。
  PageStorageBucket _yearStorage = PageStorageBucket();

  /// 释放本次面板资源。
  @override
  void dispose() {
    _pages.dispose();
    _months.dispose();
    _annual.dispose();
    super.dispose();
  }

  /// 分段点击从当前实际分页继续，不重建内容。
  void _switch(int index) {
    if (!_pages.hasClients) return;
    setState(() => _tab = index);
    if (OmniMotion.reduce(context)) {
      _pages.jumpToPage(index);
    } else {
      unawaited(
        _pages.animateToPage(
          index,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  /// 换年份才把两个列表回到开头。
  void _selectYear(int year) {
    setState(() {
      _year = year;
      _yearStorage = PageStorageBucket();
    });
    if (_months.hasClients) _months.jumpTo(0);
    if (_annual.hasClients) _annual.jumpTo(0);
  }

  /// 选日仍返回归档键，主列表与侧栏随后一起关闭。
  void _selectDay(String key) {
    if (identical(ref.read(appDatabaseProvider), widget.source)) {
      Navigator.pop(context, key);
    }
  }

  /// 顶部星期在月历滚动区之外。
  Widget _weekdays() => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: OmniSpacing.md,
      vertical: OmniSpacing.sm,
    ),
    child: Row(
      children: [
        for (final String label in ['一', '二', '三', '四', '五', '六', '日'])
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: OmniColors.of(context).muted),
            ),
          ),
      ],
    ),
  );

  /// 近全高底部表面保留原侧栏，不模糊背景。
  @override
  Widget build(BuildContext context) {
    // 正式篇聚合不受主列表过滤或草稿影响。
    final AsyncValue<NoteStatistics> result = ref.watch(noteStatisticsProvider);
    // 数据源变更时不展示可操作的其他库日期。
    final bool same = identical(ref.watch(appDatabaseProvider), widget.source);
    // 成功加载的统计快照。
    final NoteStatistics? statistics = result.value;
    if (statistics != null &&
        !result.hasError &&
        !result.isLoading &&
        !statistics.years.contains(_year)) {
      _year = statistics.years.contains(DateTime.now().year)
          ? DateTime.now().year
          : statistics.years.firstOrNull;
    }
    // 右侧复用既有年份选择，不添加更多分析入口。
    final List<int> years = statistics?.years ?? [];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .95,
      child: Column(
        key: const ValueKey('notes-statistics-dialog'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OmniSpacing.xs,
              vertical: OmniSpacing.xs,
            ),
            child: Row(
              children: [
                OmniIconButton(
                  key: const ValueKey('notes-statistics-close'),
                  tooltip: '关闭记录统计',
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: () => Navigator.pop(context),
                ),
                Expanded(
                  child: Center(
                    child: OmniSlidingSegmentedControl<int>(
                      options: const [0, 1],
                      selected: _tab,
                      width: 214,
                      height: 40,
                      labelBuilder: (value) => value == 0 ? '月' : '年',
                      itemKeyBuilder: (value) => ValueKey(
                        value == 0
                            ? 'notes-statistics-month-view'
                            : 'notes-statistics-year-view',
                      ),
                      onChanged: _switch,
                    ),
                  ),
                ),
                OmniPopupMenuButton<int>(
                  key: const ValueKey('android-statistics-year-menu'),
                  enabled: same && years.isNotEmpty,
                  initialValue: _year,
                  onSelected: _selectYear,
                  itemBuilder: (context) => [
                    for (final int year in years)
                      OmniPopupMenuItem(
                        value: year,
                        label: '$year',
                        icon: null,
                      ),
                  ],
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: OmniSize.touch,
                      minHeight: OmniSize.touch,
                    ),
                    child: Center(
                      child: Text(
                        _year?.toString() ?? '年份',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: !same
                ? const Center(child: Text('数据源已切换，请重新打开统计'))
                : result.hasError
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('统计加载失败'),
                        OmniButton(
                          label: '重试统计',
                          onPressed: () {
                            ref.invalidate(notesProvider);
                            ref.invalidate(noteStatisticsProvider);
                          },
                        ),
                      ],
                    ),
                  )
                : statistics == null
                ? const Center(child: CircularProgressIndicator())
                : _year == null
                ? const Center(child: Text('还没有记录，写下第一篇笔记吧'))
                : PageStorage(
                    bucket: _yearStorage,
                    child: NotificationListener<ScrollEndNotification>(
                      onNotification: (notification) {
                        if (notification.depth == 0 && _pages.hasClients) {
                          // 手势中途反向时，以最终实际落位校准分段选择。
                          final int page = _pages.page!.round();
                          if (_tab != page) setState(() => _tab = page);
                        }
                        return false;
                      },
                      child: PageView(
                        key: const ValueKey('android-statistics-pages'),
                        controller: _pages,
                        onPageChanged: (value) {
                          if (_tab != value) setState(() => _tab = value);
                        },
                        children: [
                          Column(
                            children: [
                              _weekdays(),
                              Expanded(child: _monthList(statistics, _year!)),
                            ],
                          ),
                          ListView(
                            key: const PageStorageKey(
                              'android-statistics-annual',
                            ),
                            controller: _annual,
                            padding: const EdgeInsets.all(OmniSpacing.md),
                            children: [
                              Text(
                                '$_year',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              for (int metric = 0; metric < 3; metric++)
                                _AndroidAnnualMetric(
                                  statistics: statistics,
                                  year: _year!,
                                  metric: metric,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 仅显示有正式记录的月份，最新月份在前。
  Widget _monthList(NoteStatistics statistics, int year) {
    // 使用共享月索引，不重复扫描正文。
    final List<String> months =
        statistics.months.keys.where((key) => key.startsWith('$year-')).toList()
          ..sort((a, b) => b.compareTo(a));
    return ListView.builder(
      key: const PageStorageKey('android-statistics-months'),
      controller: _months,
      padding: const EdgeInsets.fromLTRB(
        OmniSpacing.md,
        OmniSpacing.sm,
        OmniSpacing.md,
        OmniSpacing.xl,
      ),
      itemCount: months.length,
      itemBuilder: (context, index) => _AndroidStatisticsMonth(
        statistics: statistics,
        monthKey: months[index],
        selected: _selectDay,
      ),
    );
  }
}

/// 日期数字与热力方块组成同一个触控区，不绘制多余空周。
class _AndroidStatisticsMonth extends StatelessWidget {
  /// 共享统计快照。
  final NoteStatistics statistics;

  /// 稳定YYYY-MM月份。
  final String monthKey;

  /// 有记录日期的出口。
  final ValueChanged<String> selected;

  /// 创建单月日历。
  const _AndroidStatisticsMonth({
    required this.statistics,
    required this.monthKey,
    required this.selected,
  });

  /// 七列网格在大字号时自然增高。
  @override
  Widget build(BuildContext context) {
    // 归档年月与创建时区无关。
    final int year = int.parse(monthKey.substring(0, 4));
    // 自然月份。
    final int month = int.parse(monthKey.substring(5));
    // 月初之前的空格。
    final int offset = DateTime(year, month).weekday - 1;
    // 包含闰日的自然月长度。
    final int length = DateTime(year, month + 1, 0).day;
    // 该月份的三项合计。
    final NoteStatisticsTotals totals = statistics.month(year, month);
    // 当前年份统一热力强度，跨月仍可比较。
    final int peak = statistics.dates.entries
        .where((entry) => entry.key.startsWith('$year-'))
        .fold<int>(1, (value, entry) => math.max(value, entry.value.count));
    // 颜色继承当前主题。
    final OmniColors colors = OmniColors.of(context);
    return Padding(
      key: ValueKey('android-statistics-month-$monthKey'),
      padding: const EdgeInsets.only(bottom: OmniSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(monthKey, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: OmniSpacing.xs),
          Text(
            '${totals.count} 条笔记 · ${totals.words} 字 · 坚持记录 ${totals.days} 天',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.muted),
          ),
          const SizedBox(height: OmniSpacing.sm),
          for (int week = 0; week < ((offset + length) / 7).ceil(); week++)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int weekday = 0; weekday < 7; weekday++)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        // 格子位置转为自然日，越界只留空位。
                        final int day = week * 7 + weekday - offset + 1;
                        if (day < 1 || day > length) {
                          return const SizedBox.shrink();
                        }
                        // 选日返回稳定归档键。
                        final String key =
                            '$monthKey-${day.toString().padLeft(2, '0')}';
                        // 零记录日期不提供假按钮。
                        final NoteStatisticsTotals value =
                            statistics.dates[key] ??
                            const NoteStatisticsTotals();
                        return Semantics(
                          label: '$key，${value.count}篇笔记，${value.words}字',
                          button: value.count > 0,
                          child: OmniInkWell(
                            key: ValueKey('notes-statistics-day-$key'),
                            onTap: value.count == 0
                                ? null
                                : () => selected(key),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                                vertical: OmniSpacing.xxs,
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    '$day',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: colors.muted),
                                  ),
                                  const SizedBox(height: OmniSpacing.xxs),
                                  AspectRatio(
                                    aspectRatio: 1,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: value.count == 0
                                            ? colors.mist
                                            : colors.brand.withValues(
                                                alpha:
                                                    .18 +
                                                    .5 * value.count / peak,
                                              ),
                                        borderRadius: BorderRadius.circular(
                                          OmniRadius.control,
                                        ),
                                        border:
                                            key ==
                                                businessDayKey(DateTime.now())
                                            ? Border.all(color: colors.brand)
                                            : null,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 年度三指标沿用共享聚合，零值始终为零高度。
class _AndroidAnnualMetric extends StatelessWidget {
  /// 正式统计数据。
  final NoteStatistics statistics;

  /// 当前年份。
  final int year;

  /// 篇数、字数、天数的维度索引。
  final int metric;

  /// 创建单项年度图。
  const _AndroidAnnualMetric({
    required this.statistics,
    required this.year,
    required this.metric,
  });

  /// 读取统一模型中的指定维度。
  int _value(NoteStatisticsTotals totals) => switch (metric) {
    0 => totals.count,
    1 => totals.words,
    _ => totals.days,
  };

  /// 大字号横坐标保留宽度，必要时允许横向查看。
  @override
  Widget build(BuildContext context) {
    // 完整十二月的真实值。
    final List<int> values = List.generate(
      12,
      (index) => _value(statistics.month(year, index + 1)),
    );
    // 最大值至少为1以便绘制空轴，不抬高零柱。
    final int maximum = values.fold<int>(1, math.max);
    // 当前年度总计。
    final int total = _value(
      statistics.annual[year] ?? const NoteStatisticsTotals(),
    );
    // 图表维度颜色继承项目配色。
    final Color color = [
      OmniColors.of(context).brand,
      Theme.of(context).colorScheme.secondary,
      Theme.of(context).colorScheme.tertiary,
    ][metric];
    return Padding(
      key: ValueKey('android-statistics-annual-$metric'),
      padding: const EdgeInsets.symmetric(vertical: OmniSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$total ${['条笔记', '字', '天'][metric]}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: OmniSpacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              // 按真实字体测量刻度，避免大字号纵轴换行溢出。
              final TextStyle? labelStyle = Theme.of(context)
                  .textTheme
                  .bodySmall;
              // 横纵轴共用当前系统字号。
              final TextScaler scaler = MediaQuery.textScalerOf(context);
              // 同时测量最高纵轴值和两位月份。
              final TextPainter axis = TextPainter(
                text: TextSpan(text: '$maximum', style: labelStyle),
                textScaler: scaler,
                textDirection: Directionality.of(context),
              )..layout();
              // 刻度区至少保留原宽度，长数字自然加宽。
              final double axisWidth = math.max(
                32,
                axis.width.ceilToDouble() + 8,
              );
              axis.dispose();
              // 两位月份使用固定单行区域，各柱的基线保持一致。
              final TextPainter monthLabel = TextPainter(
                text: TextSpan(text: '12', style: labelStyle),
                textScaler: scaler,
                textDirection: Directionality.of(context),
              )..layout();
              // 月份热区与字体各自保持原始比例。
              final double cellWidth = math.max(
                24,
                monthLabel.width.ceilToDouble() + 8,
              );
              // 横轴标签的实际行高。
              final double labelHeight = monthLabel.height.ceilToDouble();
              monthLabel.dispose();
              // 十二个月份不通过缩小字号挤进窄屏。
              final double width = math.max(
                constraints.maxWidth,
                12 * cellWidth + axisWidth + OmniSpacing.sm,
              );
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: width <= constraints.maxWidth
                    ? const NeverScrollableScrollPhysics()
                    : null,
                child: SizedBox(
                  width: width,
                  height: 170 + labelHeight + OmniSpacing.xs,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (int index = 0; index < 12; index++)
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.bottomCenter,
                                        child: FractionallySizedBox(
                                          heightFactor: values[index] / maximum,
                                          child: Semantics(
                                            label:
                                                '${index + 1}月，${values[index]}${['篇', '字', '天'][metric]}',
                                            child: Container(
                                              width: 16,
                                              decoration: BoxDecoration(
                                                color: color,
                                                borderRadius:
                                                    const BorderRadius.vertical(
                                                      top: Radius.circular(
                                                        OmniRadius.tiny,
                                                      ),
                                                    ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: OmniSpacing.xs),
                                    SizedBox(
                                      height: labelHeight,
                                      child: Text(
                                        '${index + 1}',
                                        maxLines: 1,
                                        style: labelStyle,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: OmniSpacing.sm),
                      SizedBox(
                        width: axisWidth,
                        child: Padding(
                          padding: EdgeInsets.only(
                            bottom: labelHeight + OmniSpacing.xs,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '$maximum',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              Text(
                                '${(maximum / 2).floor()}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              Text(
                                '0',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
