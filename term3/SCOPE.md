# term3 scope

**The idea: a GNOME Terminal-style successor to iTerm2.** A terminal for
people leaving iTerm2 for Linux: iTerm2's good ideas (starting with the
vertical tab sidebar), GNOME Terminal's look and native feel, traditional
terminal behavior, and none of iTerm2's cruft.

Today term3 is Ghostty's Linux (GTK) app with **one opinion: tabs live in a vertical
sidebar on the left.** Everything that isn't about that sidebar, or about
shipping term3 as its own installable app, belongs upstream in Ghostty.

## The test for any change

A change is in scope only if it answers "yes" to one of these:

1. Does it improve the tab sidebar: placement, sizing, titles, reordering,
   or how readable the tabs are?
2. Is it needed for term3 to be its own app: identity, packaging, icon,
   releases, tests, docs?
3. Is it a small default that makes term3 feel native on GNOME, where
   GNOME Terminal is the reference (e.g. using the desktop monospace font)?
4. Does it restore a traditional terminal convention that Ghostty changed
   (e.g. new shells start in `$HOME`)? See "Defaults" below.

If not, it doesn't go in term3. Use upstream Ghostty, or open an issue there.

## Defaults: where to look

term3's users are moving from iTerm2, and they expect a terminal to behave
like a terminal. When choosing a default:

1. **Traditional terminal behavior wins** over newer "better UX" ideas.
   Decades of muscle memory count for more than a clever default. Where
   Ghostty changed a convention, term3 restores it and keeps Ghostty's
   behavior as an option.
2. **When in doubt, look at iTerm2** as configured by someone who has used it
   for years, not iTerm2's stock defaults. The vertical tab sidebar is the
   model: an iTerm2 idea term3 adopts on purpose.
3. **GNOME Terminal** is the reference for the look and native desktop
   integration (font, colors, cursor).
4. **No cruft.** iTerm2 is inspiration, not a spec. term3 doesn't copy its
   non-terminal extras (an embedded web browser, for example). A feature has
   to make the terminal better at being a terminal.

## In scope

| Area | Status |
| --- | --- |
| Vertical tab sidebar, left or right (`gtk-tabs-location`) | 0.1 |
| Fixed-size rows; the window never changes shape as tabs come and go | 0.1 |
| Resizable sidebar (drag), `gtk-sidebar-width` | 0.1 |
| Drag to reorder; middle-click close; right-click menu; bell dot | 0.1 |
| Long titles: `ellipsize` / `scroll` (marquee on hover) / `wrap` | 0.1 |
| Working-directory subtitle, hidden when the title already shows it | 0.1 |
| GNOME desktop monospace font as the default font (like GNOME Terminal) | 0.1 |
| Block cursor at the prompt (like GNOME Terminal) | 0.1 |
| GNOME Terminal "GNOME dark" color scheme and palette as default | 0.1 |
| Default to large browser-proportioned window (80% screen / 1280×800) with Start Maximized UI toggle | 0.1 |
| term3 identity: binary, app ID, config dir, icon, About | 0.1 |
| RPM packaging, tagged releases, test suite | 0.1 |

## Roadmap (in scope, not done yet)

See [ROADMAP.md](ROADMAP.md) for the 0.1.0 release milestone and the upcoming
transition to replace Zig with Rust.

Ordered roughly by priority. Each item must still pass the test above.

1. **Settings window.** A real preferences UI for common options (font,
   theme, sidebar options) instead of "here is a config file". It writes
   the same `~/.config/term3/config` file, so text config keeps working.
   *(Requested by the maintainer; reason for scope: native GNOME feel.)*
2. **GNOME Terminal defaults audit.** The maintainer prefers "as much of
   GNOME Terminal as possible". Compare each default (colours following
   light/dark mode, palette, scrollback size, bell, padding, word-select
   characters, copy and paste behaviour) and adopt GNOME Terminal's where it
   differs. One change per item, each with a test. Done so far: font,
   block cursor, GNOME dark color scheme and palette.
3. **Remember the sidebar width** across restarts after dragging it.
4. **Shell completions, man page, editor syntax files for `term3`.** The
   upstream ones are keyed to the `ghostty` command and are left out of the
   RPM for now.
5. **Live system font changes**: follow the GNOME setting without a config
   reload.
6. **Unvendoring.** Use more Fedora system libraries and a Fedora Zig; see
   [VENDORING.md](VENDORING.md).
7. **Translations** for the few strings term3 changed ("About term3", etc.).
8. **CI** on GitHub for the term3 test tiers.

## Explicitly out of scope

These are deliberately not term3's job. Most are upstream's.

- Terminal emulation, rendering, fonts, shaping, performance: Ghostty.
- Splits, panes, tmux-style session or window management, session restore.
  (The previous attempt at this was a chore, and agents handle it now.)
- Profiles, SSH/connection managers, AI features, plugins, scripting.
- Platforms other than Linux/GTK. No macOS app (upstream has one).
- Renaming compatibility identifiers. `TERM=xterm-ghostty`, `TERM_PROGRAM`,
  `GHOSTTY_*` variables and shell integration stay as they are, so programs
  keep detecting the terminal's features correctly.
- Diverging from upstream behaviour that isn't about tabs. A Ghostty default
  we dislike is a config line, not a patch.

## Divergence budget

The patch should stay small enough to merge upstream changes quickly.

- New code goes in new files (`src/term3.zig`, `src/apprt/gtk/class/tab_sidebar.zig`,
  `src/apprt/gtk/term3_system_font.zig`, `term3/`).
- Edits to upstream files are minimal and marked with a `term3:` comment.
- Review the whole divergence with `git diff upstream/main...main --stat`.
