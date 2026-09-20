import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_meter/main.dart';

void main() {
  testWidgets('shows the Fugui taxi meter skin', (WidgetTester tester) async {
    await tester.pumpWidget(const TaxiMeterApp());

    expect(find.text('富貴'), findsOneWidget);
    expect(find.text('設定'), findsOneWidget);
  });

  testWidgets('starts simulation when 計程計時 is tapped', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TaxiMeterApp());

    const keyLabels = ['空', '計程計時', '停', '夜間加成', '設定'];
    for (final label in keyLabels) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('計程計時'));
    await tester.pump();

    expect(find.text('模擬模式 · 停車計時'), findsOneWidget);
    // The lower row represents engraved physical keys, not dynamic labels.
    for (final label in keyLabels) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('停 pauses, 計程計時 resumes, and 空 resets a paused trip', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TaxiMeterApp());

    await tester.tap(find.text('計程計時'));
    await tester.pump();
    await tester.tap(find.text('停'));
    await tester.pump();
    expect(find.text('本趟暫停'), findsOneWidget);

    await tester.tap(find.text('計程計時'));
    await tester.pump();
    expect(find.text('模擬模式 · 停車計時'), findsOneWidget);

    await tester.tap(find.text('停'));
    await tester.pump();
    await tester.tap(find.text('空'));
    await tester.pump();
    expect(find.text('尚未開始定位'), findsOneWidget);
  });
}
