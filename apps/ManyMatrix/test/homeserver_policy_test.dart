import 'package:flutter_test/flutter_test.dart';
import 'package:manymatrix_app/src/platform/homeserver_policy.dart';

void main() {
  test('homeservers require HTTPS outside loopback development', () {
    expect(matrixHomeserverSecurityError('https://matrix.example.org'), isNull);
    expect(matrixHomeserverSecurityError('http://localhost:8008'), isNull);
    expect(matrixHomeserverSecurityError('http://127.0.0.1:8008'), isNull);
    expect(matrixHomeserverSecurityError('http://127.255.1.2:8008'), isNull);
    expect(matrixHomeserverSecurityError('http://[::1]:8008'), isNull);
    expect(
      matrixHomeserverSecurityError('http://127.evil.example:8008'),
      contains('HTTPS'),
    );
    expect(
      matrixHomeserverSecurityError('http://127.0.0.1.evil:8008'),
      contains('HTTPS'),
    );
    expect(
      matrixHomeserverSecurityError('http://127.0.0.999:8008'),
      contains('HTTPS'),
    );
    expect(
      matrixHomeserverSecurityError('http://matrix.example.org'),
      contains('HTTPS'),
    );
    expect(
      matrixHomeserverSecurityError('ftp://matrix.example.org'),
      contains('HTTPS'),
    );
  });

  test('homeserver URLs are canonicalized without accepting secret fields', () {
    expect(
      canonicalHomeserverUrl(' HTTPS://Matrix.Example.Org/base/// '),
      'https://matrix.example.org/base',
    );
    expect(canonicalHomeserverUrl('https://user:pass@example.org'), isNull);
    expect(
      canonicalHomeserverUrl('https://example.org?access_token=x'),
      isNull,
    );
    expect(canonicalHomeserverUrl('https://example.org/#token'), isNull);
    expect(
      homeserverUrlForCleanup(
        'https://user:pass@Old.Example:8448/base?access_token=x#secret',
      ),
      'https://old.example:8448/base',
    );
  });

  test('web page policy accepts HTTPS, loopback, and extension origins', () {
    expect(
      matrixWebPageSecurityError(Uri.parse('https://app.example')),
      isNull,
    );
    expect(
      matrixWebPageSecurityError(Uri.parse('http://localhost:8080')),
      isNull,
    );
    expect(
      matrixWebPageSecurityError(Uri.parse('chrome-extension://extension-id')),
      isNull,
    );
    expect(
      matrixWebPageSecurityError(Uri.parse('moz-extension://extension-id')),
      isNull,
    );
    expect(
      matrixWebPageSecurityError(Uri.parse('http://app.example')),
      contains('HTTPS'),
    );
    expect(
      matrixWebPageSecurityError(Uri.parse('file:///tmp/index.html')),
      contains('HTTPS'),
    );
  });
}
