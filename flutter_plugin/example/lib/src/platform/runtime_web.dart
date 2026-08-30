import 'package:manymatrix/manymatrix.dart';

Future<void> initializeExampleBridge() async {
  await ManyMatrixBridge.initialize('');
}

String exampleStorePath() => 'manymatrix-web-store';

String? exampleRuntimeWarning() => null;
