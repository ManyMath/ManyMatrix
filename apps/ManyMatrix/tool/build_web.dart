import 'dart:io';

Future<void> run(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  stdout.writeln('+ $executable ${arguments.join(' ')}');
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw ProcessException(executable, arguments, 'exit $exitCode', exitCode);
  }
}

Future<void> main(List<String> arguments) async {
  final appDirectory = File.fromUri(Platform.script).parent.parent;
  final repoRoot = appDirectory.parent.parent;
  final webDirectory = Directory('${appDirectory.path}/web');
  final packageDirectory = Directory('${webDirectory.path}/pkg');
  final outputDirectory = Directory('${appDirectory.path}/build/web');
  var buildMode = 'release';
  final flutterArguments = <String>[];
  for (final argument in arguments) {
    if (argument == '--debug' || argument == '--release') {
      buildMode = argument.substring(2);
    } else {
      flutterArguments.add(argument);
    }
  }
  final wasmPackMode = buildMode == 'debug' ? '--dev' : '--release';

  try {
    await run('wasm-pack', <String>[
      'build',
      '--target',
      'web',
      wasmPackMode,
      '--out-dir',
      packageDirectory.path,
      '${repoRoot.path}/crates/web',
    ], workingDirectory: repoRoot.path);

    await run('flutter', <String>[
      'build',
      'web',
      '--$buildMode',
      '--no-web-resources-cdn',
      '--no-wasm-dry-run',
      ...flutterArguments,
    ], workingDirectory: appDirectory.path);
  } on ProcessException catch (error) {
    stderr.writeln('ManyMatrix web build failed: ${error.message}');
    exitCode = error.errorCode;
    return;
  }

  final required = <String>[
    'index.html',
    'flutter_bootstrap.js',
    'manymatrix_worker.js',
    'manymatrix_worker_protocol.mjs',
    'pkg/manymatrix_web.js',
    'pkg/manymatrix_web_bg.wasm',
  ];
  for (final relativePath in required) {
    final artifact = File('${outputDirectory.path}/$relativePath');
    if (!artifact.existsSync() || artifact.lengthSync() == 0) {
      stderr.writeln('Missing web build artifact: $relativePath');
      exitCode = 1;
      return;
    }
  }

  final wasm = File(
    '${outputDirectory.path}/pkg/manymatrix_web_bg.wasm',
  ).readAsBytesSync();
  if (wasm.length < 4 ||
      wasm[0] != 0x00 ||
      wasm[1] != 0x61 ||
      wasm[2] != 0x73 ||
      wasm[3] != 0x6d) {
    stderr.writeln('Invalid ManyMatrix WASM artifact.');
    exitCode = 1;
    return;
  }

  stdout.writeln('ManyMatrix web $buildMode build: ${outputDirectory.path}');
}
