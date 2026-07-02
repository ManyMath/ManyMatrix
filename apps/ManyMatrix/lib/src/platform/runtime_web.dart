/// Web variant: the manymatrix web bridge compiles but cannot run yet.
const bool matrixRuntimeSupported = false;

/// Human-readable reason shown when [matrixRuntimeSupported] is false.
///
/// Typed `String?` to mirror the native variant, where it is null.
// ignore: unnecessary_nullable_for_final_variable_declarations
const String? matrixRuntimeUnsupportedReason =
    'Matrix on web is coming soon. The native Rust bridge is not yet '
    'available in the browser.';

/// Unused on web; present so callers compile on every platform.
String defaultLibraryPath() => '';

/// Unused on web; present so callers compile on every platform.
String defaultStorePath(String accountId) => 'manymatrix-web-store-$accountId';
