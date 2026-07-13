bool isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
    return true;
  }
  if (normalized == '::1' || normalized == '0:0:0:0:0:0:0:1') {
    return true;
  }
  final octets = normalized.split('.');
  if (octets.length != 4) return false;
  final parsed = <int>[];
  for (final octet in octets) {
    if (!RegExp(r'^[0-9]{1,3}$').hasMatch(octet)) return false;
    final value = int.parse(octet);
    if (value > 255) return false;
    parsed.add(value);
  }
  return parsed.first == 127;
}

String? canonicalHomeserverUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasScheme ||
      uri.host.isEmpty ||
      (uri.scheme.toLowerCase() != 'http' &&
          uri.scheme.toLowerCase() != 'https') ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  var path = uri.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path == '/') path = '';
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        path: path,
      )
      .toString();
}

/// Derives the non-secret URL portion needed to locate and delete state
/// created by older builds that accepted credentials/query fields.
String? homeserverUrlForCleanup(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme.toLowerCase() != 'http' &&
          uri.scheme.toLowerCase() != 'https')) {
    return null;
  }
  return canonicalHomeserverUrl(
    Uri(
      scheme: uri.scheme.toLowerCase(),
      host: uri.host.toLowerCase(),
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString(),
  );
}

String? matrixHomeserverSecurityError(String value) {
  final canonical = canonicalHomeserverUrl(value);
  if (canonical == null) {
    return 'Enter an HTTP or HTTPS homeserver URL without credentials, query parameters, or a fragment.';
  }
  final uri = Uri.parse(canonical);
  if (uri.scheme == 'https') return null;
  if (uri.scheme == 'http' && isLoopbackHost(uri.host)) return null;
  return 'Use an HTTPS homeserver. HTTP is allowed only for localhost and loopback development.';
}

String? matrixWebPageSecurityError(Uri page) {
  final scheme = page.scheme.toLowerCase();
  if (scheme == 'https' ||
      scheme == 'chrome-extension' ||
      scheme == 'moz-extension') {
    return null;
  }
  if (scheme == 'http' && isLoopbackHost(page.host)) return null;
  return 'ManyMatrix must be served over HTTPS outside localhost development.';
}
