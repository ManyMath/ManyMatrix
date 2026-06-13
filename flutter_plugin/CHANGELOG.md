# Changelog

Package-local changelog for the `manymatrix` Flutter/Dart package (as required by
[pub.dev's publishing conventions](https://dart.dev/tools/pub/publishing#important-files)).
For the full project history across the Rust workspace and this plugin together, see the
root [`CHANGELOG.md`](../CHANGELOG.md).

## [Unreleased]

## [1.0.0+2], 2026-07-03

- Rust core bumped to `0.2.0` (see root `CHANGELOG.md` `[0.2.0]`), most
  notably a fix for key backup restore silently recovering zero room keys.
  No Dart-facing API changes.

## [1.0.0+1]

- Publish-readiness metadata: `homepage`/`repository`/`issue_tracker`/`topics` in
  `pubspec.yaml`, a package-local dual MIT/Apache-2.0 `LICENSE`, and this changelog.
  Package remains `publish_to: 'none'`, see the "Local Consumption Policy" section
  of `README.md` for what's left before an actual `pub.dev` publish.

## [1.0.0], pre-release history

Everything up to and including v1.3 of the Rust workspace shipped under this package's
independent `1.0.0+1` version while still finding its shape. See the root
[`CHANGELOG.md`](../CHANGELOG.md) for the corresponding Rust/E2E milestone history.
