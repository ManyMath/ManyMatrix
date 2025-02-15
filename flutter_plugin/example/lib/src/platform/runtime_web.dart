import 'package:manymatrix/manymatrix.dart';

Future<void> initializeExampleBridge() async {
  await ManyMatrixBridge.initialize('');
}

String exampleStorePath() => 'manymatrix-web-store';

String? exampleRuntimeWarning() {
  return 'This checkout restores the web and extension build surfaces, but the '
      'runtime bridge is still unavailable in the browser.';
}
