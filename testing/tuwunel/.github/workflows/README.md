## Overview

The release pipeline `Main` (main.yml) and its subroutines defined in the other yamls form a high-level
description for the underlying self-hosted build system in  `/docker`. In other words, this is a sort of
terminal, a "thin-client" with a display and a keyboard for our docker mainframe. We minimize
vendor-lockin and duplication with other services by limiting everything here to only what is
essential for driving the docker builder.

Though we slightly relax the above by specifying details of the actual CI pipeline, the 
control-flow logic to go from some input event to some output or release here. This gives us
better integration  with github, like granular progress indications by breaking up operations
as individual jobs and workflows within the pipeline. This means we'll have duplicate logic
with other services, but only as it relates to high-level control flow.
