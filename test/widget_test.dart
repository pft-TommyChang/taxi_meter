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

    await tester.tap(find.text('計程計時'));
    await tester.pump();

    expect(find.text('模擬模式 · 停車計時'), findsOneWidget);
  });
}
