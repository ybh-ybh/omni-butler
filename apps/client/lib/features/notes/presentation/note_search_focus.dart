import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 笔记搜索焦点由页面和壳层共享，导航栏获得焦点时 Ctrl+F 仍命中笔记。
final noteSearchFocusProvider = Provider<FocusNode>((ref) {
  // 随应用容器释放，不因页面预载分配多个搜索焦点。
  final FocusNode focus = FocusNode(debugLabel: 'notes-search');
  ref.onDispose(focus.dispose);
  return focus;
});
