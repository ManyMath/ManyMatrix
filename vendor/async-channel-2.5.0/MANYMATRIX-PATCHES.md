# ManyMatrix Local Patches

This directory vendors the matrix-construct `async-channel` fork that exposes
queue strategy selection used by embedded Tuwunel.

## Changes

- Package version is set to `2.5.0` so it satisfies `matrix-sdk 0.16.0`'s
  `async-channel ^2.5.0` requirement while preserving the fork's
  `QueueStrategy` and `bounded_with_queue_strategy` API.
