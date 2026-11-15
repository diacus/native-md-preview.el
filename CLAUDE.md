# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when
working with code in this repository.

## Project Overview

`native-md-preview.el` is a single-file Emacs Lisp package providing
live Markdown preview rendered entirely inside Emacs. It converts the
buffer to HTML via an external processor (pandoc by default, through
`markdown-command`) and renders in place with
`libxml-parse-html-region` + `shr-insert-document`. No HTTP servers,
no websockets, no temporary output files.

It was extracted from the ep3c Emacs configuration
(https://github.com/diacus/ep3c, module `src/modules/markdown.org`),
following the same pattern as https://github.com/diacus/shell-edit.el:
the framework consumes the published package via quelpa and keeps only
keybindings and display customization locally.

## Layout

- `native-md-preview.el` — the whole package (one file)
- `test/native-md-preview-test.el` — ERT suite
- `test/run-tests.sh` — headless test entry point
- `.dir-locals.el` — flycheck load path for the checker + projectile test command

## Testing

```sh
./test/run-tests.sh
```

Byte-compiles the package, then runs the full ERT suite headless
(`ert-run-tests-batch-and-exit`). Exits non-zero on failure or compile
error. Needs `markdown-mode` (from `~/.emacs.d/elpa`, override with
`MARKDOWN_MODE_DIR`) and `pandoc` (tests skip otherwise).

### End-to-end testing (isolated GUI Emacs)

The batch suite cannot exercise real windows, frames or rendering.
For a full end-to-end run, spin up a dedicated Emacs daemon whose
HOME points at a throwaway directory, so no user config pollutes the
environment (this is exactly how the first e2e test was run):

1. Prepare a temporary home and install the package with its
   dependencies into it:

   ```sh
   H=~/sandbox/emacs-test-home
   mkdir -p "$H"
   # dependencies (MELPA)
   env HOME="$H" emacs --batch --eval '(progn (require (quote package)) (add-to-list (quote package-archives) (quote ("melpa" . "https://melpa.org/packages/")) t) (package-initialize) (package-refresh-contents) (package-install (quote markdown-mode)))'
   # the package under test
   env HOME="$H" emacs --batch -l package --eval '(progn (package-initialize) (package-install-file "/home/diacus/src/native-md-preview.el/native-md-preview.el"))'
   ```

   Gotcha: `package-install-file` gets `~` expanded to the *new* HOME,
   so always pass an absolute path.

2. Launch a dedicated GUI daemon on a named socket, with the display
   environment of the current desktop session (pgtk needs
   `DISPLAY`, `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` or it exits):

   ```sh
   env HOME="$H" DISPLAY=:0 WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 \
       /usr/bin/emacs-pgtk --fg-daemon=nmdp-test &
   ```

   On Emacs 30 named-daemon sockets live in `$XDG_RUNTIME_DIR/emacs/`,
   NOT in `$HOME/.emacs.d/server/`.

3. Drive it with `emacsclient` against that socket:

   ```sh
   S=-s /run/user/1000/emacs/nmdp-test
   printf '# Hello\n\nSome **markdown**.\n' > "$H/smoke.md"
   env DISPLAY=:0 WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 \
       emacsclient -c -n $S "$H/smoke.md"          # open a GUI frame
   ```

   `-c` without `-n` blocks until the frame closes; use `-n`.  Verify
   by probing state through the same socket with `-e`, e.g.:

   ```sh
   emacsclient $S -e '(with-current-buffer "smoke.md"
                        (native-md-preview-toggle)
                        (list native-md-preview-mode
                              (buffer-name native-md-preview--preview-buffer)))'
   ```

   Expect: mode non-nil, preview buffer named
   `*native-md-preview:smoke.md*`, rendered text inside it, and —
   with the frame visible — typing in the source buffer refreshing
   the preview after the debounce delay without any save.

4. Tear down: `M-x kill-emacs` from a client frame, or kill the
   process.  The temporary home can be kept between runs (elpa
   download caching) or deleted for a fully fresh environment.

State probes through `emacsclient -e` should use `with-current-buffer`
blocks (state lives in the source/preview buffers), and remember the
toggle-then-read batch trap does not apply to the live server: there
`select-window` really does change what the user's frame shows, which
is the behavior being tested.

### Batch-mode pitfalls (learned the hard way)

- Code that ends with `(select-window W)` (e.g. `--enable` returning to
  the source window) switches the current buffer to W's buffer. Wrap
  each toggle call and each assertion in its own `with-current-buffer`;
  reading state in the same `with-current-buffer` body right after a
  toggle silently reads `*scratch*` instead.
- Batch buffers must be shown via `(set-window-buffer (selected-window)
  buf)` before any window-dependent code; `(get-buffer-window buf)` is
  nil for undisplayed buffers.
- `window-scroll-functions` never fire (no redisplay) — call the hook
  functions directly.
- For scroll-sync assertions, check `window-start` (set by
  `set-window-start`) — `window-point` is restored by the
  `with-selected-window` wrappers and doesn't reflect the sync.
- Checkdoc in batch (`checkdoc-file`) silently auto-joins flagged
  docstrings. Lint with `(setq checkdoc-autofix-flag nil)` first.

## Conventions

- All public identifiers use the `native-md-preview` prefix; machinery
  is `native-md-preview--` (private).
- The codebase is kept in sync with the ep3c module it came from
  (bug fixes are backported to
  `ep3c:src/modules/markdown.org` and vice versa) until publication.
- checkdoc-clean: two spaces between sentences, quoted symbols in
  docstrings, imperative docstring verbs.
- License: GPL-3.0-or-later (inherited from ep3c). Keep the SPDX and
  GPL header on new files.
