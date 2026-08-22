import 'package:manymatrix/manymatrix.dart';

Future<void> initializeExampleBridge() async {
  await ManyMatrixBridge.initialize('');
}

String exampleStorePath() => 'manymatrix-web-store';

String? exampleRuntimeWarning() {
  return 'This example supports web and extension builds, but its '
      'runtime bridge is still unavailable in the browser.';
}
