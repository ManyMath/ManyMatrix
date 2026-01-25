# ManyMatrix Local Patches

This directory vendors the matrix-construct `event-listener 5.4.1` fork that
adds queue strategy selection. The vendored `async-channel` fork re-exports
`QueueStrategy` through `event-listener-strategy`, and embedded Tuwunel relies
on that API for database pool scheduling.
