import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:manymatrix_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boots to the login screen', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: ManyMatrixApp(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Matrix Login'), findsOneWidget);
    expect(find.text('Homeserver URL'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
  });
}
