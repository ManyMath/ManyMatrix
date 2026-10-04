import 'homeserver_policy.dart';

/// Ordinary browsers run the Rust core in an account-scoped module Worker.
const bool matrixRuntimeSupported = true;

/// Web bridge secrets live in tab-scoped sessionStorage (ordinary site) or
/// extension storage, never SharedPreferences/localStorage.
const bool matrixBridgeOwnsSessionPersistence = true;

String? homeserverSecurityError(String value) {
  final pageError = matrixWebPageSecurityError(Uri.base);
  if (pageError != null) return pageError;
  return matrixHomeserverSecurityError(value);
}

/// Human-readable reason shown when [matrixRuntimeSupported] is false.
///
/// Typed `String?` to mirror the native variant, where it is null.
// ignore: unnecessary_nullable_for_final_variable_declarations
const String? matrixRuntimeUnsupportedReason = null;

/// The web bridge resolves its packaged Worker and WASM assets itself.
String defaultLibraryPath() => '';

/// Stable, account-specific IndexedDB namespace passed to the Worker.
///
/// Async to match the native variant, which resolves a platform directory.
Future<String> defaultStorePath(String accountId) async =>
    'manymatrix-web-store-$accountId';
