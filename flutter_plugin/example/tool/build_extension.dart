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

Future<void> main() async {
  final scriptDir = File.fromUri(Platform.script).parent;
  final exampleDir = scriptDir.parent;
  final buildWebDir = Directory('${exampleDir.path}/build/web');
  final extensionSrcDir = Directory('${exampleDir.path}/extension');
  final extensionBuildDir = Directory('${exampleDir.path}/build/extension');
  final zipPath = '${exampleDir.path}/build/extension.zip';

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

  if (extensionBuildDir.existsSync()) {
    extensionBuildDir.deleteSync(recursive: true);
  }
  extensionBuildDir.createSync(recursive: true);

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

  final zipFile = File(zipPath);
  if (zipFile.existsSync()) {
    zipFile.deleteSync();
  }

  await run('zip', ['-qr', zipPath, '.'], cwd: extensionBuildDir.path);
  stdout.writeln('Built $zipPath');
}
