import "package:flutter_test/flutter_test.dart";

import "package:flutter_nzm/main.dart";

void main() {
  testWidgets("app smoke test", (WidgetTester tester) async {
    await tester.pumpWidget(const NzmFlutterApp());
    expect(find.text("NZM"), findsWidgets);
  });
}
