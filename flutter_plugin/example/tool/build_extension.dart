import 'dart:io';

Future<void> run(
  String cmd,
  List<String> args, {
  required String cwd,
}) async {
  stdout.writeln('+ $cmd ${args.join(' ')}');
  final result = await Process.run(cmd, args, workingDirectory: cwd);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw ProcessException(cmd, args, 'exit ${result.exitCode}', result.exitCode);
  }
}

void copyTree(Directory src, Directory dest) {
  if (!dest.existsSync()) {
    dest.createSync(recursive: true);
  }

  for (final entity in src.listSync(recursive: false)) {
    final name = entity.uri.pathSegments.last;
    final targetPath = '${dest.path}/$name';
    if (entity is Directory) {
      copyTree(entity, Directory(targetPath));
    } else if (entity is File) {
      File(targetPath)
        ..createSync(recursive: true)
        ..writeAsBytesSync(entity.readAsBytesSync());
    }
  }
}

Future<void> checkWasmPack() async {
  try {
    final result = await Process.run('wasm-pack', ['--version']);
    if (result.exitCode != 0) {
      stderr.writeln(
        '[build_extension] step "wasm-pack" failed: wasm-pack returned '
        'exit ${result.exitCode}. Install: '
        'curl https://rustwasm.github.io/wasm-pack/installer/init.sh -sSf | sh',
      );
      exit(1);
    }
    stdout.writeln('Found ${(result.stdout as String).trim()}');
  } on ProcessException {
    stderr.writeln(
      '[build_extension] step "wasm-pack" failed: wasm-pack not found in PATH. '
      'Install: '
      'curl https://rustwasm.github.io/wasm-pack/installer/init.sh -sSf | sh',
    );
    exit(1);
  }
}

Future<void> runWasmPack(String repoRoot, String outDir) async {
  await run(
    'wasm-pack',
    [
      'build',
      '--target',
      'web',
      '--release',
      '--out-dir',
      outDir,
      '$repoRoot/crates/web',
    ],
    cwd: repoRoot,
  );
}

void verifyArtifacts(Directory dir) {
  final required = [
    'pkg/manymatrix_web_bg.wasm',
    'pkg/manymatrix_web.js',
    'offscreen.html',
    'offscreen.js',
    'sw.js',
    'manifest.json',
    'flutter_bootstrap.js',
    'index.html',
  ];
  for (final path in required) {
    if (!File('${dir.path}/$path').existsSync()) {
      stderr.writeln(
        '[build_extension] step "manifest-verify" failed: missing $path',
      );
      exit(1);
    }
  }
  stdout.writeln('All required artifacts verified.');
}

Future<void> main() async {
  final scriptDir = File.fromUri(Platform.script).parent;
  final exampleDir = scriptDir.parent;
  final repoRoot = exampleDir.parent.parent.path;
  final buildWebDir = Directory('${exampleDir.path}/build/web');
  final extensionSrcDir = Directory('${exampleDir.path}/extension');
  final extensionBuildDir = Directory('${exampleDir.path}/build/extension');
  final zipPath = '${exampleDir.path}/build/extension.zip';

  try {
    await checkWasmPack();
  } catch (_) {
    exit(1);
  }

  try {
    await run(
      'flutter',
      [
        'build',
        'web',
        '--csp',
        '--no-web-resources-cdn',
        '--no-wasm-dry-run',
        '--release',
      ],
      cwd: exampleDir.path,
    );
  } on ProcessException catch (e) {
    stderr.writeln('[build_extension] step "flutter-build" failed: ${e.message}');
    exit(1);
  }

  if (extensionBuildDir.existsSync()) {
    extensionBuildDir.deleteSync(recursive: true);
  }
  extensionBuildDir.createSync(recursive: true);

  try {
    await runWasmPack(repoRoot, '${extensionBuildDir.path}/pkg');
  } on ProcessException catch (e) {
    stderr.writeln('[build_extension] step "wasm-pack" failed: ${e.message}');
    exit(1);
  }

  copyTree(buildWebDir, extensionBuildDir);
  copyTree(extensionSrcDir, extensionBuildDir);

  final bootstrapFile = File('${extensionBuildDir.path}/flutter_bootstrap.js');
  if (bootstrapFile.existsSync()) {
    final patched = bootstrapFile.readAsStringSync().replaceAll(
      RegExp(
        r'_flutter\.loader\.load\(\{\s*serviceWorkerSettings:\s*\{.*?\}\s*\}\);',
        dotAll: true,
      ),
      '_flutter.loader.load({});',
    );
    bootstrapFile.writeAsStringSync(patched);
  }

  final indexFile = File('${extensionBuildDir.path}/index.html');
  final indexHtml = indexFile.readAsStringSync();
  final inlineScriptPattern = RegExp(
    r'<script(?![^>]*\bsrc=)[^>]*>',
    caseSensitive: false,
  );
  if (inlineScriptPattern.hasMatch(indexHtml)) {
    stderr.writeln('Inline <script> blocks are not allowed in the extension.');
    exit(1);
  }

  verifyArtifacts(extensionBuildDir);

  final zipFile = File(zipPath);
  if (zipFile.existsSync()) {
    zipFile.deleteSync();
  }

  try {
    await run('zip', ['-qr', zipPath, '.'], cwd: extensionBuildDir.path);
  } on ProcessException catch (e) {
    stderr.writeln('[build_extension] step "zip" failed: ${e.message}');
    exit(1);
  }
  stdout.writeln('Built $zipPath');
}
