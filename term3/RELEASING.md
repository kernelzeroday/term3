# Releasing term3

## Versions

term3 has its **own** semver, independent of Ghostty's.

- **Where:** `pub const version` in `src/term3.zig`, the single source of
  truth. `term3/scripts/version.sh` reads it for scripts and the RPM.
- **Ghostty's version is never changed.** Programs read it (XTVERSION) to
  detect terminal features. `term3 +version` and the About window show both
  versions, e.g. `term3 0.1.0-rc.1 (ghostty 1.4.1-dev+f28124c73)`.
- **0.x** while the sidebar and packaging settle. Minor bumps (0.1 → 0.2)
  for features, patch bumps (0.1.0 → 0.1.1) for fixes and upstream merges.
- **Pre-releases** use semver's `-rc.N`: `0.1.0-rc.1`, `0.1.0-rc.2`, then
  `0.1.0`. In the RPM the dash becomes `~` (`0.1.0~rc.1`), so RPM sorts
  release candidates before the final release and upgrades work.

| What | Example |
| --- | --- |
| term3 version | `0.1.0-rc.1` |
| Git tag | `term3-v0.1.0-rc.1` |
| RPM | `term3-0.1.0~rc.1-1.fc45.aarch64.rpm` |
| GitHub release | "term3 0.1.0-rc.1", marked pre-release |

**Why the `term3-` tag prefix:** upstream's `vX.Y.Z` tags are Ghostty
releases and exist in this repo's history. A bare `v0.1.0` would be
ambiguous, and Ghostty's build treats a `v*` tag on HEAD as a Ghostty
release. The build skips `term3-*` tags (`src/build/Config.zig`).

## Checklist

1. Merge upstream if wanted (see "Upstream" below) and run the tests.
2. Set the version in `src/term3.zig`, and add a section to
   `term3/CHANGELOG.md`.
3. Commit: `term3: release 0.1.0-rc.1`.
4. `term3/scripts/release.sh`. It checks the tree is clean, that the version,
   changelog and tag agree, and that the tests pass. It then builds the RPMs,
   creates the annotated tag and, after asking, pushes the tag and creates a
   GitHub release with the RPMs and source tarballs attached.

To install a release:

```sh
sudo dnf install ./term3-0.1.0~rc.1-1.fc45.$(uname -m).rpm
```

## Upstream

`main` is Ghostty plus term3 commits. Bring in upstream with a **merge**,
not a rebase. Release tags then stay on `main`'s history, and the public
branch never needs a force-push.

```sh
git fetch upstream
git merge upstream/main          # resolve conflicts in the term3-marked spots
term3/tests/run.sh
```

`git diff upstream/main...main` is always exactly term3's patch. The release
notes record the Ghostty base (`term3/scripts/version.sh --ghostty`).
