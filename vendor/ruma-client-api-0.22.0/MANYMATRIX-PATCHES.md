# ManyMatrix Local Patches

This directory vendors `ruma-client-api 0.22.0` from crates.io so the workspace
can build `matrix-sdk 0.16.0` while preserving `.cargo/config.toml`'s
`ruma_unstable_exhaustive_types` cfg.

## Changes

- `src/push/set_pushrule.rs`: handle `NewPushRule::PostContent` when
  `unstable-msc4306` is enabled. `matrix-sdk 0.16.0` enables this Ruma feature,
  and exhaustive Ruma types make the missing upstream match arm a hard compile
  error.
- `src/profile/set_profile_field.rs`: gate `ProfileFieldValueVisitor` import
  behind the `server` feature to avoid an unused import warning in the client-only
  feature set used by ManyMatrix.
