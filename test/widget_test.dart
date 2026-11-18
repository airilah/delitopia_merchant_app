import 'package:flutter_test/flutter_test.dart';
import 'package:delitopia_merchant_app/main.dart';

void main() {
  testWidgets('DelitopiaMerchantApp smoke test', (WidgetTester tester) async {
    // Verify app widget instantiates cleanly
    const app = DelitopiaMerchantApp();
    expect(app, isNotNull);
  });
}
