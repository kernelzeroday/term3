# Vendored and bundled code

This file lists every piece of third-party code in a term3 build: how it gets
in, whether the term3 RPM uses Fedora's copy, and the path to unvendoring it.
It comes from Ghostty's own dependency setup; term3 adds no dependencies.

## How dependencies get in

| Mechanism | Where | Pinned by |
| --- | --- | --- |
| **Zig packages** | Fetched at build time from `deps.files.ghostty.org`, cached in `zig-pkg/` (gitignored) | Content hash in `build.zig.zon` / `pkg/*/build.zig.zon` |
| **In-tree vendor** | `vendor/`, `pkg/simdutf/vendor/` | Committed in git |
| **System libraries** | Fedora packages, via pkg-config | The RPM's `BuildRequires` |
| **Build toolchain** | Zig compiler tarball from ziglang.org | `minimum_zig_version` in `build.zig.zon`; `%zig_version` in the spec |

The RPM build is **offline**. `term3/scripts/make-sources.sh` packs every Zig
package (`deps/packages.txt`) into `term3-<ver>-zig-deps.tar.gz`, and the
spec builds with `zig build --system <that dir>`, which disables fetching.

Ghostty can link a system copy of many C libraries with **`-fsys=<name>`**.
That is the unvendoring mechanism. **Note:** under `zig build --system`
(package mode, which the RPM uses) Zig turns on *every* system integration by
default, so the spec opts out (`-fno-sys=<name>`) of whatever should stay
bundled. The RPM's `system_libs` switch (on by default) keeps Fedora's copies.
Build everything bundled with `term3/scripts/build-rpm.sh --without system_libs`.

Verified 2026-11-09 by an offline build from the release tarballs: the binary
links Fedora's libfontconfig, libfreetype, libharfbuzz, libpng16, libz and
libgtk4-layer-shell.

## Status

**Legend:** **system**: the RPM links Fedora's library. **bundled**: compiled
into term3 from the pinned source. **candidate**: Fedora has it and
`-fsys` exists, but it hasn't been verified for term3 yet. **Zig-only**: a Zig
library with no system form (Zig has no shared-library ecosystem, so these are
bundled everywhere, including in Ghostty's own distro packages).

### C/C++ libraries

| Library | Used for | License | Fedora 45 | term3 RPM | Path to unvendor |
| --- | --- | --- | --- | --- | --- |
| GTK 4, libadwaita, GLib, Pango, Cairo | UI | LGPL-2.1+ | yes | **system** | already |
| wayland-client, libX11, libEGL (libglvnd) | windowing, GL | MIT | yes | **system** | already |
| gtk4-layer-shell | quick terminal | MIT | 1.3.0 | **system** (`-fsys`) | already |
| fontconfig | font discovery | HPND-style | 2.18.3 | **system** (`-fsys`) | already |
| freetype | font rasterizing | FTL OR GPL-2.0+ | 2.14.3 | **system** (`-fsys`) | already |
| harfbuzz | text shaping | MIT ("Old MIT") | 15.0.0 | **system** (`-fsys`) | already |
| libpng | images | libpng-2.0 | 1.6.59 | **system** (`-fsys`) | already |
| zlib | compression | Zlib | zlib-ng-compat | **system** (`-fsys`) | already |
| oniguruma | URL/link regex | BSD-2-Clause | 6.9.10 | **system** (`-fsys`) | already |
| libxml2 | bundled fontconfig's config parser | MIT | 2.15.4 | **system** (via Fedora's fontconfig) | already (not built when fontconfig is system) |
| glslang | shader compile (GLSL→SPIR-V) | BSD-3-Clause and others | 16.3.0 | bundled | candidate: add `-fsys=glslang`, test |
| highway | SIMD dispatch | Apache-2.0 OR BSD-3-Clause | 1.3.0 | bundled | candidate: add `-fsys=highway`, test |
| simdutf (`pkg/simdutf/vendor/`) | fast UTF-8 | Apache-2.0 OR MIT | 7.2.1 | bundled | candidate: add `-fsys=simdutf`, test (pulls in libstdc++) |
| SPIRV-Cross | shader translate (SPIR-V→GLSL) | Apache-2.0 | **not packaged** | bundled | package it for Fedora first, then `-fsys=spirv-cross` |
| Dear ImGui / dcimgui | terminal inspector UI | MIT | no (no stable ABI) | bundled | stays bundled (upstream intends static use) |
| wuffs | image decoding (kitty graphics) | Apache-2.0 OR MIT | no | bundled | stays bundled (single-file, generated) |
| glad (`vendor/glad/`) | OpenGL loader | (WTFPL OR CC0-1.0) AND Apache-2.0 | n/a | bundled | stays: generated code, not a library |
| stb (`src/stb/`) | image helpers | MIT OR Unlicense | n/a | bundled | stays: single-header |
| breakpad, sentry | crash reports | BSD / MIT | n/a | **not built** for Linux | n/a |

### Zig libraries (Zig-only)

| Package | Used for | License |
| --- | --- | --- |
| libxev | event loop | MIT |
| uucode | Unicode tables | MIT |
| vaxis, zf, zigimg | CLI TUIs (`+list-themes`), fuzzy match, images | MIT |
| z2d | 2D drawing (box/sprite glyphs) | MPL-2.0 |
| zig-gobject bindings (generated) | GTK bindings for Zig | see upstream ghostty-org/zig-gobject |
| zig-wayland, translate-c, aro | build-time code generation | MIT |
| wayland, wayland-protocols, plasma-wayland-protocols | protocol XML (build time) | MIT / LGPL-2.1 (XML only) |

**Path to unvendor:** none needed. Zig statically links Zig code by design.
These are pinned by content hash and built from source, which is how
distributions package all Zig software today.

### Data

| Package | Used for | License | Notes |
| --- | --- | --- | --- |
| JetBrains Mono 2.304 | embedded fallback font | OFL-1.1 | term3 defaults to the GNOME monospace font. This is the fallback when no font is found. |
| Nerd Fonts Symbols 3.4.0 | embedded icon glyphs | MIT (+OFL for some glyphs) | |
| iTerm2-Color-Schemes | `theme = …` files in `share/term3/themes` | MIT | Could be split into a `term3-themes` subpackage. |
| `vendor/nerd-fonts/font-patcher.py` | developer tool, not built | MIT | not shipped |

### Build toolchain

| Tool | Status | Path to unvendor |
| --- | --- | --- |
| Zig 0.17.x | The RPM bundles the upstream tarball as a build-only source (not installed). Fedora 45 ships 0.16. | When Fedora ships Zig 0.17, replace Source2/Source3 with `BuildRequires: zig >= 0.17, zig < 0.18`. |
| blueprint-compiler, gettext, pkg-config | **system** | already |

## Unvendoring plan

In order, each step independently shippable:

1. **Done in 0.1:** system fontconfig, freetype, harfbuzz, libpng, zlib,
   oniguruma, gtk4-layer-shell (and libxml2, through fontconfig).
2. **Verify the candidates:** remove `-fno-sys=glslang`/`highway`/`simdutf`
   from the spec's `bundled_always`, add their `BuildRequires`, build, run
   `term3/tests/run.sh --all`, and drop their `bundled()` Provides.
3. **Zig from Fedora** once Fedora has 0.17. This drops two sources and makes
   the SRPM buildable in Koji/COPR without network access to ziglang.org.
4. **SPIRV-Cross:** package it for Fedora (it's used by other projects),
   then `-fsys=spirv-cross`.
5. **Themes subpackage** (optional) so the 400+ theme files are separate.

Anything that stays bundled must be listed in the spec as
`Provides: bundled(<name>)` with its license in `License:`.
