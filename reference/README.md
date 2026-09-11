# reference/

The 0.3.4 source files from the task package, unchanged, kept here so the
adapter and this repository's documentation can be read against the code they
target.

* `Motion.swift`, `MouthTimeline.swift`, `DesktopController.swift`, `SelfTest.swift`

They are **not** compiled by this package and are not part of the deliverable.
They are a snapshot for compatibility reference only; the app remains the owner
of all of it.

The one place they are mirrored is
`integrations/ChoreographyHostKit/MotionHostShim.swift`, which reproduces the
handful of `Motion.swift` types the adapter mentions so it can be type-checked
and tested here. That file is behind the `CHOREOGRAPHY_HOST_SHIM` compilation
flag and compiles to nothing inside the app.
