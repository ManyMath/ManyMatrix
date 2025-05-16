import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:manymatrix_example/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(
      const ProviderScope(
        child: ManyMatrixApp(),
      ),
    );

    // Verify that login screen is shown (search for "ManyMatrix" or similar)
    // Actually ManyMatrixApp uses GoRouter initialLocation: '/login'
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
