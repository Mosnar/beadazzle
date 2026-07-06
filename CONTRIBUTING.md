# Contributing to Beadazzle

Thanks for your interest in Beadazzle.

## Before You Start

- Beadazzle is a native macOS SwiftPM app targeting macOS 14 and newer.
- Install Xcode or the Xcode command line tools.
- Install `bd` if you want to exercise write flows locally.
- Keep `script/build_and_run.sh` as the single local app launch entrypoint.

## Local Setup

Preferred repo-local commands:

```bash
rtk swift build
rtk swift test
rtk ./script/build_and_run.sh --verify
./script/test_release_common.sh
```

If you are not using `rtk`, the equivalent raw commands are `swift build`, `swift test`, and `./script/build_and_run.sh --verify`.

## Contribution Guidelines

- Keep changes focused and consistent with the current macOS sidebar/list/detail structure.
- Favor SwiftUI first; only use AppKit interop for narrow platform edges.
- Do not edit generated output in `.build/`, `.swiftpm/`, or `dist/`.
- Route Beads creates, updates, deletes, dependency changes, and similar write operations through `bd`, not direct file or database writes.
- If you touch release scripts, run `./script/test_release_common.sh` and the relevant build/package validation commands.
- If you touch app behavior, run the relevant tests plus `rtk ./script/build_and_run.sh --verify` before opening a PR.

## Pull Requests

Please include:

- a short summary of what changed,
- any relevant screenshots for UI updates,
- the commands you ran to verify the change,
- and any known limitations or follow-up work.

Small, reviewable pull requests are preferred over broad multi-topic changes.