import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/theme/app_theme.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_execution_progress.dart';
import 'package:omni_butler/features/assistant/presentation/assistant_windows_tokens.dart';

/// Measure real layout bounds so tighter spacing is verified independently.
void main() {
  for (final bool compact in <bool>[false, true]) {
    testWidgets('Execution progress spacing compact=$compact', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(brightness: Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Column(
                children: <Widget>[
                  AssistantExecutionProgress(
                    compact: compact,
                    elapsedMs: 1000,
                    running: false,
                    steps: <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'one',
                        'label': '分析任务',
                        'status': 'failed',
                      },
                    ],
                    colors: AssistantWindowsPalette.of(context),
                  ),
                  const Text('回答正文', key: ValueKey<String>('answer')),
                ],
              ),
            ),
          ),
        ),
      );
      // The separator must sit close to both the header and following answer.
      final Rect header = tester.getRect(
        find.byKey(const ValueKey<String>('assistant-execution-toggle')),
      );
      // Divider bounds include exactly its configured one-pixel line.
      final Rect line = tester.getRect(find.byType(Divider));
      // The next content starts after the progress component's bottom spacing.
      final Rect answer = tester.getRect(
        find.byKey(const ValueKey<String>('answer')),
      );
      expect(line.top - header.bottom, compact ? 3 : 9);
      expect(answer.top - line.bottom, compact ? 6 : 18);
      await tester.tap(
        find.byKey(const ValueKey<String>('assistant-execution-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('分析任务'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
