;;; native-md-preview.el --- Live Markdown preview inside Emacs using shr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Diacus Magnuz

;; Author: Diacus Magnuz <diacus.magnuz@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (markdown-mode "2.6"))
;; Keywords: markdown, preview, convenience
;; URL: https://github.com/diacus/native-md-preview.el

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Live Markdown preview that renders entirely inside Emacs.
;;
;; Converts the current buffer to HTML with an external Markdown
;; processor (by default `markdown-command', i.e. pandoc) and renders
;; the result in place using `libxml-parse-html-region' followed by
;; `shr-insert-document'.  No HTTP servers, no websockets, no temporary
;; output files.
;;
;; Highlights:
;;
;; - Preview refreshes on a debounce as you type; saving is not
;;   required.
;; - Every Markdown document gets its own preview buffer
;;   (`native-md-preview-buffer-name-prefix'), so several documents can
;;   be previewed at the same time.
;; - Bidirectional proportional scroll synchronization between the
;;   source buffer and the preview window.
;; - Source code blocks are highlighted with the current theme's
;;   font-lock faces.  The language set is whatever `markdown-command'
;;   supports (`pandoc --list-highlight-languages' with the default
;;   pandoc); fenced blocks with a language tag it does not know
;;   render as plain unstyled code.
;; - Markdown tables are drawn as box-drawn grids in a fixed-pitch
;;   face, honoring cell alignment.  Header rows are optionally shaded
;;   through `native-md-preview-table-header-face'.  Shr's own table
;;   rendering is available through `native-md-preview-table-renderer'.
;;
;; Enable with `native-md-preview-mode' or `native-md-preview-toggle'
;; from a `markdown-mode' or `gfm-mode' buffer.
;;
;; External dependency: a Markdown processor such as pandoc on the
;; PATH, configured through `markdown-command'.

;;; Code:

(require 'markdown-mode)
(require 'shr)
(require 'color)

(defgroup native-md-preview nil
  "Live markdown preview settings."
  :group 'markdown
  :link '(url-link :tag "Repository" "https://github.com/diacus/native-md-preview.el"))

(defcustom native-md-preview-buffer-name-prefix "*native-md-preview"
  "Prefix for preview buffer names.
The full name is constructed as `native-md-preview-buffer-name-prefix'
plus a colon-separated suffix derived from the source buffer's name or
file path, closed with an asterisk.  This ensures each markdown document
gets its own preview buffer, e.g. *native-md-preview:README.md*."
  :type 'string
  :group 'native-md-preview)

(defcustom native-md-preview-debounce-time 0.3
  "Idle seconds before updating preview after a change."
  :type 'number
  :group 'native-md-preview)

(defcustom native-md-preview-token-faces
  '(("kw" . font-lock-keyword-face)
    ("cf" . font-lock-keyword-face)
    ("im" . font-lock-keyword-face)
    ("co" . font-lock-comment-face)
    ("do" . font-lock-comment-face)
    ("an" . font-lock-comment-face)
    ("rm" . font-lock-comment-face)
    ("cv" . font-lock-comment-face)
    ("in" . font-lock-comment-face)
    ("st" . font-lock-string-face)
    ("ss" . font-lock-string-face)
    ("vs" . font-lock-string-face)
    ("ch" . font-lock-string-face)
    ("sc" . font-lock-string-face)
    ("dv" . font-lock-constant-face)
    ("bn" . font-lock-constant-face)
    ("fl" . font-lock-constant-face)
    ("cn" . font-lock-constant-face)
    ("at" . font-lock-constant-face)
    ("fu" . font-lock-function-name-face)
    ("va" . font-lock-variable-name-face)
    ("dt" . font-lock-type-face)
    ("op" . font-lock-builtin-face)
    ("bu" . font-lock-builtin-face)
    ("ot" . font-lock-builtin-face)
    ("ex" . font-lock-builtin-face)
    ("pp" . font-lock-preprocessor-face)
    ("wa" . font-lock-warning-face)
    ("al" . font-lock-warning-face)
    ("er" . font-lock-warning-face))
  "Mapping of pandoc syntax highlighting token classes to faces.
Each element has the form (TOKEN-CLASS . FACE), where TOKEN-CLASS is
one of the two-letter CSS classes pandoc emits around highlighted
code tokens and FACE is the face whose foreground colors the token in
the preview.

Token classes not listed here are rendered with the default code
color.  Set a class to nil to disable its highlighting.

The mapping is resolved on every preview refresh, so changes to
themes or faces take effect on the next re-render.

Which languages receive highlighting at all, and how a fenced
block's language tag selects a highlighter, is decided by
`markdown-command'.  With the default pandoc, tags are matched
against the exact canonical language name (e.g. \"python\", not
\"py\"), tags unknown to the processor render as plain unstyled code,
and the supported languages can be listed with
\"pandoc --list-highlight-languages\"."
  :type '(repeat (cons (string :tag "Token class")
                       (choice (face :tag "Face")
                               (const :tag "None" nil))))
  :group 'native-md-preview)

;; Table glyph styling.

(defcustom native-md-preview-table-horizontal-line ?─
  "Character used to draw the horizontal rules between table rows.
Only used when `native-md-preview-table-renderer' is `shr'; the
boxed-grid renderer draws its own rules.  Bound to
`shr-table-horizontal-line' while the preview renders, so changes
take effect on the next preview refresh.

Set this to nil for no horizontal rules at all, which was the
rendering before table styling was introduced.

This setting is ignored when `native-md-preview-table-collapse' is
non-nil: shr draws a collapsed table without any rulers."
  :type '(choice (const :tag "None" nil) character)
  :group 'native-md-preview)

(defcustom native-md-preview-table-vertical-line ?│
  "Character used to draw the vertical rules between table columns.
The rule character draws as a continuous line with
`native-md-preview-table-horizontal-line' and
`native-md-preview-table-corner', boxing the columns.  Ignored when
`native-md-preview-table-collapse' is non-nil.  Changes take effect
on the next preview refresh."
  :type 'character
  :group 'native-md-preview)

(defcustom native-md-preview-table-corner ?─
  "Character used to draw the corners where table rules meet.
Using the same character as `native-md-preview-table-horizontal-line'
draws continuous full-width rules; any other character punctuates the
rules with corners between the columns.  Ignored when
`native-md-preview-table-collapse' is non-nil.  Changes take effect
on the next preview refresh."
  :type 'character
  :group 'native-md-preview)

(defcustom native-md-preview-table-header-face nil
  "Face whose background shades the table header cells, if any.
The face's `:background' is resolved against the active theme and
injected into the header cells as an inline style.  The default nil
leaves headers with the cell background.  Set it to a face with a
background to shade every table's header row.  Resolution happens on
every preview refresh, so changes to themes or faces take effect on
the next re-render."
  :type '(choice (const :tag "None" nil) face)
  :group 'native-md-preview)

(defcustom native-md-preview-table-collapse nil
  "Whether table borders are collapsed, CSS style.
Only used when `native-md-preview-table-renderer' is `shr'; the
boxed-grid renderer draws its own rules.  When non-nil, every
`table' element gets `border-collapse: collapse'
injected as an inline style before rendering, and shr draws the table
without cell separators or row rulers; when nil, tables are drawn
with the characters from `native-md-preview-table-horizontal-line',
`native-md-preview-table-vertical-line' and
`native-md-preview-table-corner'.

This setting takes precedence over the character settings: a
collapsed table ignores them.  Tables that already specify
`border-collapse' in their HTML are left untouched.  Changes take
effect on the next preview refresh."
  :type 'boolean
  :group 'native-md-preview)

;; In source buffer: reference to preview buffer
(defvar-local native-md-preview--preview-buffer nil)

;; In source buffer: reference to preview window
(defvar-local native-md-preview--preview-window nil)

;; In preview buffer: reference to source buffer
(defvar-local native-md-preview--source-buffer nil)

;; Timer for debounced updates
(defvar-local native-md-preview--timer nil)

;; Scroll-sync plumbing: hook fires during redisplay, and modifications
;; made to another window during its redisplay pass only take effect on
;; a LATER full redisplay - in practice when the user switches focus.
;; So the hooks only record the scroll that needs mirroring; a
;; zero-second timer applies it after the current redisplay, outside
;; redisplay context.
(defvar native-md-preview--pending-window nil
  "Window whose scroll is waiting to be mirrored by the idle sync.")
(defvar native-md-preview--pending-reverse nil
  "Whether the pending scroll wants reverse (preview) mirroring.")
(defvar native-md-preview--sync-timer nil
  "Timer scheduled to apply the pending scroll sync.")

;; Forward declaration: defined below by `define-minor-mode'
(defvar native-md-preview-mode nil)

;; In source buffer: reference to preview buffer
(defvar-local native-md-preview--preview-buffer nil)

;; In source buffer: reference to preview window
(defvar-local native-md-preview--preview-window nil)

;; In preview buffer: reference to source buffer
(defvar-local native-md-preview--source-buffer nil)

;; Timer for debounced updates
(defvar-local native-md-preview--timer nil)

;; Scroll-sync plumbing: hook fires during redisplay, and modifications
;; made to another window during its redisplay pass only take effect on
;; a LATER full redisplay - in practice when the user switches focus.
;; So the hooks only record the scroll that needs mirroring; a
;; zero-second timer applies it after the current redisplay, outside
;; redisplay context.
(defvar native-md-preview--pending-window nil
  "Window whose scroll is waiting to be mirrored by the idle sync.")
(defvar native-md-preview--pending-reverse nil
  "Whether the pending scroll wants reverse (preview) mirroring.")
(defvar native-md-preview--sync-timer nil
  "Timer scheduled to apply the pending scroll sync.")

;; Forward declaration: defined below by `define-minor-mode'
(defvar native-md-preview-mode nil)

(defun native-md-preview--buffer-name (&optional source-buffer)
  "Compute preview buffer name for SOURCE-BUFFER (defaults to current).
Derives a unique name from the source buffer's file or buffer name so
that each markdown document has its own preview buffer.  The naming
scheme:
- file-visiting buffer: PREFIX:FILENAME
- non-file buffer: PREFIX:BUFFER-NAME"
  (let* ((source (or source-buffer (current-buffer)))
         (prefix native-md-preview-buffer-name-prefix)
         (suffix (or (when-let ((file (buffer-file-name source)))
                       (file-name-nondirectory file))
                     (buffer-name source))))
    (format "%s:%s*" prefix suffix)))

(defun native-md-preview--base-href ()
  "Compute the base href for the current buffer's location.
A file:// URL of the directory of the visited file, or of the
buffer's default-directory for non-file buffers; nil when it cannot
be determined.  shr uses the document's base element to expand
relative image paths and links (which pandoc emits for every local
image in the document)."
  (when-let* ((dir (file-name-directory
                    (directory-file-name
                     (or buffer-file-name default-directory)))))
    (url-encode-url (concat "file://" (expand-file-name dir)))))

(defun native-md-preview--face-color (face &optional attribute)
  "Return foreground (or ATTRIBUTE) of FACE as an RGB hex string, or nil.
ATTRIBUTE defaults to `:foreground'.  Resolution follows the face's
`:inherit' chain against the active theme.  A color already given as
an #rrggbb string is returned verbatim, downcased; other color names
are resolved with `color-name-to-rgb', which is exact on a real
display.  Returns nil when the color is not resolvable, e.g. for
faces left unspecified when no theme is loaded (batch mode)."
  (let ((color (face-attribute face (or attribute :foreground) nil t)))
    (when (and (stringp color)
               (not (string-empty-p color)))
      (or (and (string-match-p "^#[0-9a-fA-F]\\{6\\}$" color)
               (downcase color))
          (when-let* ((rgb (color-name-to-rgb color)))
            (pcase-let ((`(,r ,g ,b) rgb))
              (format "#%02x%02x%02x"
                      (round (* 255 r))
                      (round (* 255 g))
                      (round (* 255 b)))))))))

(defconst native-md-preview--token-span-regexp
  "<span[[:space:]]+class=\"\\([a-z][a-z]\\)\">"
  "Regexp matching a pandoc syntax highlighting token span.
Pandoc emits one such span per token, always a bare two-letter
skylighting class and no other attributes; longer classes (e.g.
\"sourceCode\", \"math display\") never match and every non-code
span class pandoc emits for prose is longer than two letters.
Whitespace after \"span\" is allowed because pandoc wraps long
lines even inside tags.")

(defun native-md-preview--token-styles ()
  "Compute token class to color mapping for the current theme.
Returns an alist whose keys are pandoc token class strings and whose
values are CSS style strings (e.g. \"color:#569cd6\"), derived from
`native-md-preview-token-faces'.  Classes whose face has no
resolvable foreground are skipped, so callers treat a missing entry
as \"unstyled\"."
  (let (styles)
    (dolist (entry native-md-preview-token-faces)
      (let ((class (car entry))
            (face (cdr entry)))
        (when-let* ((face face)
                    (hex (native-md-preview--face-color face)))
          (push (cons class (format "color:%s" hex)) styles))))
    (nreverse styles)))

(defun native-md-preview--highlight-code-tokens (html styles)
  "Inject token colors from STYLES into the HTML string.
Argument HTML is pandoc's HTML output; STYLES is the alist computed
by `native-md-preview--token-styles'.  Every pandoc token span of a
known class gets its color as an inline style attribute, the only
span styling `shr-insert-document' honors.  Classes without an
entry in STYLES are left untouched, and HTML without token spans
(e.g. produced with --no-highlight, or by a markdown command other
than pandoc) is returned unchanged."
  (if (null styles)
      html
    (replace-regexp-in-string
     native-md-preview--token-span-regexp
     (lambda (match)
       (let* ((class (match-string 1 match))
              (style (cdr (assoc class styles))))
         (if style
             (format "<span class=\"%s\" style=\"%s\">" class style)
           match)))
     html t)))

(defconst native-md-preview--table-open-regexp
  "<table\\([[:space:]][^>]*\\)?>"
  "Regexp matching a `table' open tag with its attribute list.
Group 1 holds the attributes and does not match at all for a bare
`table' tag.  Whitespace or the closing bracket must follow
\"table\" directly, so closing tags and other table-ish tags (e.g.
\"<tablestyle>\") never match.  Only lowercase tag names match,
which is what well-formed HTML output such as pandoc's emits.
Attribute values containing a literal \">\" would truncate the
match; well-formed HTML writers never emit those.")

(defconst native-md-preview--th-open-regexp
  "<th\\([[:space:]][^>]*\\)?>"
  "Regexp matching a table header cell open tag.
Group 1 holds the attributes and does not match at all for a bare
`th' tag.  Same shape guarantees as
`native-md-preview--table-open-regexp': closing and other `th'-ish
tags (e.g. \"<thead>\") never match.")

(defconst native-md-preview--tbody-tags-regexp
  "</?\\(thead\\|tbody\\)>"
  "Regexp matching table section wrappers.
Pandoc wraps every table's header in `thead' and body in `tbody';
without them shr nests sections into sub-tables when a table has a
header row, which boxes the table twice.")

(defun native-md-preview--flatten-tables (html)
  "Remove `thead' and `tbody' wrappers from the tables in HTML.
Argument HTML is pandoc's HTML output; the rows are left in place, so
their cells keep their styling.  shr nests table sections into the
sub-tables described in `native-md-preview--tbody-tags-regexp' to
emulate browsers, boxing the table twice; without the wrappers it
renders the rows directly.  HTML without section wrappers is returned
unchanged."
  (replace-regexp-in-string native-md-preview--tbody-tags-regexp "" html t))

(defun native-md-preview--style-table-headers (html bg)
  "Shade the table header cells of HTML with the background BG.
Argument HTML is pandoc's HTML output; BG is a #rrggbb string from
`native-md-preview--face-color', or nil for no styling.  Each header
cell open tag gets the color injected as an inline style attribute,
the only form of cell styling `shr-insert-document' honors; tags
whose attributes already contain `background-color' are left
untouched, and cells with a style attribute get the color appended to
it.  HTML without header cells is returned unchanged, as is HTML when
BG is nil."
  (if (not bg)
      html
    (replace-regexp-in-string
     native-md-preview--th-open-regexp
     (lambda (tag)
       ;; The lambda must leave the match data untouched: the caller's
       ;; `replace-match' below still reads it, and this body's inner
       ;; `string-match' on ATTRS would clobber it.
       (save-match-data
         (let ((attrs (match-string 1 tag))
               (tail (format " style=\"background-color:%s\">" bg)))
           (cond
            ((null attrs)
             (format "<th style=\"background-color:%s\">" bg))
            ((string-match-p "background-color" attrs)
             tag)
            ((string-match "style=\"\\([^\"]*\\)\"" attrs)
             (format "<th style=\"%s;background-color:%s\">"
                     (string-remove-suffix
                      ";" (string-trim-left (match-string 1 attrs)))
                     bg))
            (t
             (concat "<th" attrs tail))))))
     html t t)))

(defcustom native-md-preview-table-renderer 'grid
  "How tables are rendered in the preview.
`grid' draws each table as its own box-drawn grid in a fixed-pitch
face, with continuous rules, character-based column sizing and
shaded header cells; `shr' falls back to shr's own pixel-based table
machinery, which uses the table rule characters from
`native-md-preview-table-horizontal-line' and friends and honors
`native-md-preview-table-collapse' (with a header row, its emulation
of browser behavior nests the sections, boxing the table twice).
Changes take effect on the next preview refresh."
  :type '(choice (const :tag "Box-drawn grid" grid)
                 (const :tag "shr's table rendering" shr))
  :group 'native-md-preview)
;;; Scratch development of the boxed-grid table renderer -*- lexical-binding: t; -*-

(require 'shr)
(require 'color)

(defun native-md-preview--table-rule (widths kind)
  "Return a horizontal box-drawing rule for WIDTHS.
KIND is the rule shape: `top', `middle' or `bottom'."
  (let ((left (pcase kind ('top "┌") ('middle "├") (_ "└")))
        (join (pcase kind ('top "┬") ('middle "┼") (_ "┴")))
        (right (pcase kind ('top "┐") ('middle "┤") (_ "┘"))))
    (concat left
            (mapconcat
             (lambda (width) (make-string (+ width 2) ?─))
             widths join)
            right)))

(defun native-md-preview--table-cell (cell)
  "Render CELL as a boxed grid table cell.
CELL is a `td' or `th' DOM node.  Returns a list (LINES HEADER ALIGN
BG), where LINES is the cell's content as strings carrying the face
properties of the content, HEADER is non-nil for a `th' cell, ALIGN
is the cell's `text-align' style value when the document specifies
one, and BG is the cell's own `background-color' style value, if any."
  (let* ((header (eq (dom-tag cell) 'th))
         (style (shr-parse-style (dom-attr cell 'style)))
         (align (cdr (assq 'text-align style)))
         (bg (cdr (assq 'background-color style)))
         (shr-fill-text nil)
         lines)
    (with-temp-buffer
      (shr-descend (cons 'span (cons nil (dom-children cell))))
      (goto-char (point-min))
      (while (not (eobp))
        (push (buffer-substring (line-beginning-position)
                                (line-end-position))
              lines)
        (forward-line 1))
      (setq lines (nreverse lines))
      ;; Drop the blank lines shr leaves around paragraphs, but keep
      ;; interior ones (from explicit line breaks).
      (while (and lines (string-empty-p (string-trim (car lines))))
        (pop lines))
      (while (and lines (string-empty-p (string-trim (car (last lines)))))
        (nbutlast lines)))
    (list (or lines (list "")) header align bg)))

(defun native-md-preview--table-rows (dom)
  "Return GRID, the cell rows of table DOM, padded to a common width.
Each GRID row is a list of cells as returned by `native-md-preview--table-cell'."
  (let ((rows ()) ncols grid)
    (dolist (row (dom-non-text-children dom))
      (when (and (not (stringp row)) (eq (dom-tag row) 'tr))
        (push (mapcar #'native-md-preview--table-cell
                      (dom-non-text-children row))
              rows)))
    (setq grid (nreverse rows)
          ncols (apply #'max (cons 1 (mapcar #'length grid))))
    (dotimes (i (length grid))
      (let ((row (nth i grid)))
        (while (< (length row) ncols)
          (setq row (append row (list (list (list "") nil nil nil)))))
        (setcar (nthcdr i grid) row)))
    grid))

(defun native-md-preview--table-widths (grid)
  "Compute the display width of each column of GRID.
GRID is as returned by `native-md-preview--table-rows'.  Each column
fits its widest cell line with one blank space on each side."
  (let ((widths (make-vector (length (car grid)) 0)))
    (dolist (row grid)
      (dotimes (i (length row))
        (dolist (line (car (nth i row)))
          (aset widths i
                (max (aref widths i) (string-width line))))))
    widths))

(defun native-md-preview--table-header-row-p (row)
  "Whether every cell of ROW is a header cell.
ROW is a list of cells as returned by `native-md-preview--table-cell'."
  (and row
       (not (member nil (mapcar (lambda (cell) (nth 1 cell)) row)))))

(defun native-md-preview--table-pad (line width align)
  "Pad LINE with spaces to WIDTH columns given ALIGN.
ALIGN is nil, \"left\", \"center\" or \"right\"; one blank space
buffers the text from the cell borders.  The result is two display
characters wider than WIDTH."
  (let* ((tw (string-width line))
         (extra (max 0 (- width tw)))
         (lpad (pcase align
                 ("right" (make-string extra ?\s))
                 ("center" (make-string (/ extra 2) ?\s))
                 (_ "")))
         (rpad (make-string (- extra (length lpad)) ?\s)))
    ;; one buffer space at each side of the cell
    (list (concat " " lpad line rpad " "))))

(defun native-md-preview--table-stage (grid widths)
  "Assemble GRID with WIDTHS in a temp buffer.
Returns (TEXT HEADER-REGIONS): TEXT is the assembled box drawing
carrying the face properties of cell contents, HEADER-REGIONS is a
list of (BEG END COLOR) shading regions, positions relative to TEXT."
  (with-temp-buffer
    (let (header-regions)
      (insert (native-md-preview--table-rule widths 'top) "\n")
      (dotimes (i (length grid))
        (let* ((row (nth i grid))
               (row-lines (apply #'max (cons 1 (mapcar (lambda (c) (length (car c))) row)))))
          (dotimes (l row-lines)
            (progn
              (dotimes (c (length widths))
                (let* ((cell (nth c row))
                       (bg (and (nth 1 cell) (nth 3 cell)))
                       (line (or (nth l (car cell)) ""))
                       (beg-cell (point)))
                  (insert "│")
                  (insert (mapconcat
                           #'identity
                           (native-md-preview--table-pad line (aref widths c) (nth 2 cell))
                           ""))
                  (when bg
                    (push (list (1+ beg-cell) (point) bg) header-regions))))
              (insert "│\n")))
          (let ((next (and (< (1+ i) (length grid)) (nth (1+ i) grid))))
            (when (and (native-md-preview--table-header-row-p row)
                       (or (null next)
                           (not (native-md-preview--table-header-row-p next))))
              (insert (native-md-preview--table-rule widths 'middle) "\n")))))
      (insert (native-md-preview--table-rule widths 'bottom) "\n")
      (list (buffer-substring (point-min) (point))
            (nreverse header-regions)))))

(defun native-md-preview--table-render (dom)
  "Render table DOM at point as a box-drawn grid.
Bound to `shr-external-rendering-functions' for `table' tags when
`native-md-preview-table-renderer' is `grid', in place of shr's own
pixel-based table machinery, which nests rows in sections.  The whole
grid is drawn in a fixed-pitch face so columns align, header cells get
the background their HTML specifies, and cell content keeps the faces
shr applied while rendering it inline.  The fixed-pitch face pins the
default face's height as well as the family, otherwise the box
drawing characters fall back to the family's default size while the
cell text keeps the buffer's face height, and the columns drift."
  (let* ((grid (native-md-preview--table-rows dom))
         (widths (native-md-preview--table-widths grid))
         (staged (native-md-preview--table-stage grid widths))
         (beg (point))
         (height (face-attribute 'default :height nil t))
         (face (if (integerp height)
                   (list :family "Monospace" :height height)
                 '(:family "Monospace"))))
    (insert (car staged))
    (add-face-text-property beg (point) face nil)
    (dolist (region (cadr staged))
      (let ((pos (+ beg (car region))))
        (add-face-text-property pos (+ beg (cadr region))
                                (list :background (caddr region))
                                nil
                                nil)))))

(defun native-md-preview--collapse-tables (html collapse)
  "Inject `border-collapse: collapse' into every table in HTML.
Argument HTML is pandoc's HTML output; COLLAPSE is the boolean
`native-md-preview-table-collapse' read by the caller in the source
buffer's context (a let-binding of a variable with a buffer-local
value would itself be buffer-local, and thus invisible to this
function's temp-buffer scope).  Each `table' open tag gets the CSS
declaration injected as an inline style attribute, the only place
`shr-insert-document' honors table styling; tags whose attributes
already contain `border-collapse' are left untouched, and tables
without a style attribute get one.  HTML without any `table' open tag
is returned unchanged, as is HTML when COLLAPSE is nil."
  (if (not collapse)
      html
    (replace-regexp-in-string
     native-md-preview--table-open-regexp
     (lambda (tag)
       ;; The lambda must leave the match data untouched: the caller's
       ;; `replace-match' below still reads it, and this body's inner
       ;; `string-match' on ATTRS would clobber it.
       (save-match-data
         (let ((attrs (match-string 1 tag)))
           (cond
            ((null attrs)
             "<table style=\"border-collapse: collapse\">")
            ((string-match-p "border-collapse" attrs)
             tag)
            ((string-match "style=\"\\([^\"]*\\)\"" attrs)
             (format "<table style=\"border-collapse: collapse;%s\">"
                     (string-trim-left (match-string 1 attrs))))
            (t
             (concat "<table" attrs
                     " style=\"border-collapse: collapse\">"))))))
     html t t)))

(defun native-md-preview--to-html ()
  "Convert current markdown buffer to HTML string.
Wraps in minimal HTML structure for proper rendering, including a
base element pointing at the buffer's location, so that shr expands
relative image paths and links against the document's directory.
Highlighted code token spans get inline color styles resolved from
`native-md-preview-token-faces'."
  (let ((content (buffer-string))
        (cmd (if (boundp 'markdown-command) markdown-command "pandoc"))
        (base (native-md-preview--base-href))
        ;; Capture the table settings in this buffer's context for the
        ;; transforms below, which run inside temp buffers.
        (table-collapse native-md-preview-table-collapse)
        (table-header-bg (when native-md-preview-table-header-face
                           (native-md-preview--face-color
                            native-md-preview-table-header-face
                            :background))))
    ;; Use temp file for reliable pandoc input
    (let ((temp-file (make-temp-file "md-preview" nil ".md")))
      (unwind-protect
          (progn
            (with-temp-file temp-file
              (insert content))
            (with-temp-buffer
              (call-process cmd nil t nil
                            "--from=gfm" "--to=html"
                            temp-file)
              (let* ((html (native-md-preview--collapse-tables
                            (native-md-preview--style-table-headers
                             (native-md-preview--highlight-code-tokens
                              (native-md-preview--flatten-tables
                               (buffer-string))
                              (native-md-preview--token-styles))
                             table-header-bg)
                            table-collapse)))
                ;; Wrap in HTML structure for better shr rendering
                (format "<!DOCTYPE html>
<html>
<head><meta charset=\"utf-8\">%s
<style>
body { font-family: sans-serif; margin: 2em; line-height: 1.6; }
h1, h2, h3 { margin-top: 1.5em; }
code { background: #f5f5f5; padding: 0.2em 0.4em; }
pre { background: #f5f5f5; padding: 1em; overflow-x: auto; }
</style>
</head>
<body>
%s
</body>
</html>"
                        ;; A local location gets a base element on its own
                        ;; head line; a location-less buffer gets none.
                        (if base
                            (format "\n<base href=\"%s\">" base)
                          "")
                        html))))
        (delete-file temp-file)))))

(defun native-md-preview--render-html (html)
  "Render HTML string into current buffer using shr.
Argument HTML is the HTML string to render.

Parses HTML via `libxml-parse-html-region' and renders via
`shr-insert-document' directly.  This avoids `shr-render-buffer' which
calls `pop-to-buffer' and would create a new `*html*' buffer on every
refresh, leaking buffers.  The table rule characters are let-bound
from the `native-md-preview-table' customizable variables, so they
apply at every render."
  (let ((inhibit-read-only t)
        (shr-table-horizontal-line native-md-preview-table-horizontal-line)
        (shr-table-vertical-line native-md-preview-table-vertical-line)
        (shr-table-corner native-md-preview-table-corner)
        (shr-external-rendering-functions
         (when (eq native-md-preview-table-renderer 'grid)
           '((table . native-md-preview--table-render)))))
    (erase-buffer)
    (shr-insert-document
     (with-temp-buffer
       (insert html)
       (libxml-parse-html-region (point-min) (point-max))))
    (goto-char (point-min))))

(defun native-md-preview--refresh (source-buf preview-buf)
  "Refresh the preview buffer for SOURCE-BUF.
Argument PREVIEW-BUF is the preview buffer to refresh.

A re-render replaces the preview buffer's text and would otherwise
reset the preview window to the top of the buffer while the source
keeps its position; re-anchor the preview after rendering, from the
source's visible position, or - when the source is not displayed
anywhere - from the preview's previous relative position."
  (when (and (buffer-live-p source-buf)
             (buffer-live-p preview-buf))
    ;; Save window focus to prevent stealing focus during update
    (save-selected-window
      (let* ((source-win (car (get-buffer-window-list source-buf nil t)))
             (prev-win (car (get-buffer-window-list preview-buf nil t)))
             ;; Position to restore when the source has no visible window
             (old-start (when prev-win
                          (with-current-buffer preview-buf
                            (line-number-at-pos (window-start prev-win)))))
             (old-total (when prev-win
                          (with-current-buffer preview-buf
                            (count-lines (point-min) (point-max))))))
        (let ((html (with-current-buffer source-buf
                      (native-md-preview--to-html))))
          (with-current-buffer preview-buf
            (native-md-preview--render-html html))
          (cond
           ((and source-win (window-live-p source-win))
            ;; Re-anchor from the source's current view; the scroll
            ;; sync stamps the preview window, so the move does not
            ;; echo back as a reverse sync.
            (native-md-preview--sync-scroll source-win))
           ((and prev-win (window-live-p prev-win) old-total (> old-total 0))
            (let* ((new-total (with-current-buffer preview-buf
                                (count-lines (point-min) (point-max))))
                   (target-line (max 1
                                     (floor (* (/ (float old-start) old-total)
                                               new-total)))))
              (with-selected-window prev-win
                (goto-char (point-min))
                (forward-line (1- target-line))
                (set-window-parameter prev-win
                                      'native-md-preview-sync-start
                                      (point))
                (set-window-start prev-win (point))
                (set-window-point prev-win (point)))))))))))

(defun native-md-preview--schedule-refresh ()
  "Schedule a debounced preview refresh."
  (when (and native-md-preview-mode
             native-md-preview--preview-buffer
             (buffer-live-p native-md-preview--preview-buffer))
    (when (timerp native-md-preview--timer)
      (cancel-timer native-md-preview--timer))
    ;; Capture buffer references for the timer callback
    (let ((source (current-buffer))
          (preview native-md-preview--preview-buffer))
      (setq native-md-preview--timer
            (run-with-idle-timer native-md-preview-debounce-time nil
                                 #'native-md-preview--refresh
                                 source preview)))))

(defun native-md-preview--after-change (&rest _)
  "Hook for `after-change-functions' to trigger preview update."
  (native-md-preview--schedule-refresh))

(defun native-md-preview--sync-scroll (window)
  "Sync preview buffer scroll position with source buffer.
Argument WINDOW is the source window being scrolled.
Intended as a `window-scroll-functions' entry for the source buffer.

All state is read relative to WINDOW's buffer: the hook may fire for a
window that is not selected, or from a redisplay context where the
current buffer is unrelated.  The preview window's point follows its
start; leaving it behind lets redisplay pull the start back to make a
stale point visible, undoing the scroll."
  (when (buffer-live-p (window-buffer window))
    (with-current-buffer (window-buffer window)
      (when (and native-md-preview-mode
                 native-md-preview--preview-buffer
                 (buffer-live-p native-md-preview--preview-buffer)
                 (window-live-p native-md-preview--preview-window))
        (let* ((preview-buffer native-md-preview--preview-buffer)
               (preview-window native-md-preview--preview-window)
               (source-total (count-lines (point-min) (point-max)))
               (source-line (line-number-at-pos (window-start window)))
               (preview-total (with-current-buffer preview-buffer
                                (count-lines (point-min) (point-max))))
               ;; Calculate target line proportionally
               (target-line (if (zerop source-total)
                                1
                              (max 1 (floor (* (/ (float source-line) source-total)
                                               preview-total))))))
          ;; Set preview window start position; keep point with it.
          ;; Stamp BEFORE the move: in a GUI, set-window-start fires
          ;; window-scroll-functions synchronously, so the echo of
          ;; this move can arrive within this very call - if we
          ;; stamped after it, the echo would see a stale stamp and
          ;; re-sync, cascading.
          (with-selected-window preview-window
            (goto-char (point-min))
            (forward-line (1- target-line))
            (set-window-parameter preview-window
                                  'native-md-preview-sync-start
                                  (point))
            (set-window-start preview-window (point))
            (set-window-point preview-window (point))))))))

(defun native-md-preview--schedule-sync ()
  "Schedule the outside-of-redisplay application of a pending sync."
  (when (timerp native-md-preview--sync-timer)
    (cancel-timer native-md-preview--sync-timer))
  (setq native-md-preview--sync-timer
        (run-with-timer 0 nil #'native-md-preview--process-pending-sync)))

(defun native-md-preview--process-pending-sync ()
  "Apply the scroll recorded by the hooks, outside redisplay."
  (setq native-md-preview--sync-timer nil)
  (when native-md-preview--pending-window
    (let ((window native-md-preview--pending-window)
          (reverse native-md-preview--pending-reverse))
      (setq native-md-preview--pending-window nil)
      (when (window-live-p window)
        (if reverse
            (native-md-preview--reverse-sync-scroll window)
          (native-md-preview--sync-scroll window))))))

(defun native-md-preview--sync-scroll-hook (window &rest _)
  "Hook for `window-scroll-functions' to record forward syncs.
Do not sync here: window-scroll-functions run during redisplay, and
the mirrored window would only visibly update on a later focus
change.  The actual work is deferred by
`native-md-preview--schedule-sync'."
  (let ((last (window-parameter window 'native-md-preview-sync-start)))
    (if (and last (= (window-start window) last))
        ;; Our own programmatic scroll echoed back; consume and skip.
        (set-window-parameter window 'native-md-preview-sync-start nil)
      (setq native-md-preview--pending-window window
            native-md-preview--pending-reverse nil)
      (native-md-preview--schedule-sync))))

(defun native-md-preview--reverse-sync-scroll (window)
  "Sync source buffer scroll position with preview buffer.
Argument WINDOW is the preview window being scrolled.
Like `native-md-preview--sync-scroll', state is read relative to
WINDOW's buffer, and the source windows' points follow their starts
so redisplay does not undo the scroll."
  (when (buffer-live-p (window-buffer window))
    (let* ((source-buffer nil)
           (source-windows nil)
           (preview-total (with-current-buffer (window-buffer window)
                            (count-lines (point-min) (point-max))))
           (preview-line (line-number-at-pos (window-start window)))
           source-total)
      (with-current-buffer (window-buffer window)
        (setq source-buffer native-md-preview--source-buffer)
        (when (buffer-live-p source-buffer)
          (setq source-windows (get-buffer-window-list source-buffer nil t)
                source-total (with-current-buffer source-buffer
                               (count-lines (point-min) (point-max))))))
      (when source-windows
        (let ((target-line (if (zerop preview-total)
                               1
                             (max 1 (floor (* (/ (float preview-line) preview-total)
                                              source-total))))))
          (dolist (source-win source-windows)
            (with-selected-window source-win
              (goto-char (point-min))
              (forward-line (1- target-line))
              ;; Stamp BEFORE the move, same rationale as in
              ;; `native-md-preview--sync-scroll'.
              (set-window-parameter source-win
                                    'native-md-preview-sync-start
                                    (point))
              (set-window-start source-win (point))
              (set-window-point source-win (point)))))))))

(defun native-md-preview--reverse-sync-scroll-hook (window &rest _)
  "Hook for `window-scroll-functions' to record reverse syncs.
Like `native-md-preview--sync-scroll-hook', only records; the work is
deferred outside redisplay."
  (let ((last (window-parameter window 'native-md-preview-sync-start)))
    (if (and last (= (window-start window) last))
        ;; Our own programmatic scroll echoed back; consume and skip.
        (set-window-parameter window 'native-md-preview-sync-start nil)
      (setq native-md-preview--pending-window window
            native-md-preview--pending-reverse t)
      (native-md-preview--schedule-sync))))

(defun native-md-preview--delete-window-or-frame (buffer)
  "Delete windows showing BUFFER or their frames.
If BUFFER is the only window in its frame, delete the frame.
Otherwise delete just the window."
  (dolist (win (get-buffer-window-list buffer nil t))
    (when (window-live-p win)
      (let ((frame (window-frame win)))
        (if (= (length (window-list frame)) 1)
            (delete-frame frame)
          (delete-window win))))))

(defun native-md-preview--cleanup-source ()
  "Cleanup when source buffer is killed."
  (when native-md-preview--preview-buffer
    ;; Cancel timers
    (when (timerp native-md-preview--timer)
      (cancel-timer native-md-preview--timer))
    (setq native-md-preview--timer nil)
    (when (timerp native-md-preview--sync-timer)
      (cancel-timer native-md-preview--sync-timer))
    (setq native-md-preview--sync-timer nil
          native-md-preview--pending-window nil
          native-md-preview--pending-reverse nil)
    ;; Remove hooks
    (remove-hook 'after-change-functions #'native-md-preview--after-change t)
    (remove-hook 'kill-buffer-hook #'native-md-preview--kill-hook t)
    (remove-hook 'window-scroll-functions #'native-md-preview--sync-scroll-hook t)
    ;; Clean up preview buffer
    (when (buffer-live-p native-md-preview--preview-buffer)
      (native-md-preview--delete-window-or-frame native-md-preview--preview-buffer)
      (kill-buffer native-md-preview--preview-buffer))
    ;; Clear state
    (setq native-md-preview--preview-buffer nil
          native-md-preview--preview-window nil)))

(defun native-md-preview--cleanup-preview ()
  "Cleanup when preview buffer is killed."
  ;; Remove reverse sync hook from preview buffer
  (remove-hook 'window-scroll-functions #'native-md-preview--reverse-sync-scroll-hook t)
  (when-let ((source native-md-preview--source-buffer))
    (when (buffer-live-p source)
      (with-current-buffer source
        (when native-md-preview-mode
          ;; Cancel timer
          (when (timerp native-md-preview--timer)
            (cancel-timer native-md-preview--timer))
          ;; Remove hooks
          (remove-hook 'after-change-functions #'native-md-preview--after-change t)
          (remove-hook 'kill-buffer-hook #'native-md-preview--kill-hook t)
          (remove-hook 'window-scroll-functions #'native-md-preview--sync-scroll-hook t)
          ;; Clear mode and state
          (setq native-md-preview-mode nil
                native-md-preview--preview-buffer nil
                native-md-preview--preview-window nil))))))

(defun native-md-preview--kill-hook ()
  "Buffer-local kill hook; call the appropriate cleanup."
  (if native-md-preview--source-buffer
      ;; We're in the preview buffer
      (native-md-preview--cleanup-preview)
    ;; We're in the source buffer
    (native-md-preview--cleanup-source)))

(defun native-md-preview--enable ()
  "Enable native-md-preview for current buffer."
  (unless (derived-mode-p 'markdown-mode 'gfm-mode)
    (user-error "Native-md-preview requires markdown-mode or gfm-mode"))
  (let* ((source (current-buffer))
         (preview-name (native-md-preview--buffer-name source))
         (html (native-md-preview--to-html))
         ;; Reuse the existing preview buffer for this source if any
         ;; (e.g., user disabled and re-enabled without changes).
         (preview (or (get-buffer preview-name)
                      (get-buffer-create preview-name)))
         (source-window (selected-window))
         (preview-window (display-buffer preview '(display-buffer-pop-up-window)))
         (actual-preview (window-buffer preview-window)))
    ;; Set up preview buffer
    (with-current-buffer actual-preview
      (native-md-preview--render-html html)
      (setq-local native-md-preview--source-buffer source)
      (add-hook 'kill-buffer-hook #'native-md-preview--kill-hook nil t)
      (add-hook 'window-scroll-functions #'native-md-preview--reverse-sync-scroll-hook nil t))
    ;; Set up source buffer - store both buffer AND window
    (with-current-buffer source
      (setq-local native-md-preview--preview-buffer actual-preview)
      (setq-local native-md-preview--preview-window preview-window)
      (add-hook 'after-change-functions #'native-md-preview--after-change nil t)
      (add-hook 'kill-buffer-hook #'native-md-preview--kill-hook nil t)
      (add-hook 'window-scroll-functions #'native-md-preview--sync-scroll-hook nil t))
    ;; Return to source window
    (select-window source-window)))

(defun native-md-preview--disable ()
  "Disable native-md-preview for current buffer."
  ;; Cancel timers
  (when (timerp native-md-preview--timer)
    (cancel-timer native-md-preview--timer))
  (setq native-md-preview--timer nil)
  (when (timerp native-md-preview--sync-timer)
    (cancel-timer native-md-preview--sync-timer)
    (setq native-md-preview--sync-timer nil
          native-md-preview--pending-window nil
          native-md-preview--pending-reverse nil))
  ;; Remove hooks
  (remove-hook 'after-change-functions #'native-md-preview--after-change t)
  (remove-hook 'kill-buffer-hook #'native-md-preview--kill-hook t)
  (remove-hook 'window-scroll-functions #'native-md-preview--sync-scroll-hook t)
  ;; Clean up preview buffer
  (when (buffer-live-p native-md-preview--preview-buffer)
    (native-md-preview--delete-window-or-frame native-md-preview--preview-buffer)
    (kill-buffer native-md-preview--preview-buffer))
  ;; Clear state
  (setq native-md-preview--preview-buffer nil
        native-md-preview--preview-window nil))

;;;###autoload
(define-minor-mode native-md-preview-mode
  "Toggle live markdown preview mode.

When enabled, displays an HTML preview of the current markdown buffer.
The preview updates as you type.  The preview buffer is named uniquely
per source document, so multiple markdown files can have independent
previews.  Uses `shr-insert-document' and `libxml-parse-html-region'
for in-Emacs rendering without temporary files.

Behavior on source buffer kill:
- If preview window is only window in frame: delete frame
- Otherwise: delete just preview window

Killing preview buffer disables this mode."
  :lighter " MD-Preview"
  :keymap (make-sparse-keymap)
  (if native-md-preview-mode
      (native-md-preview--enable)
    (native-md-preview--disable)))

;;;###autoload
(defun native-md-preview-toggle ()
  "Toggle native-md-preview for current buffer.

Creates a preview window showing rendered HTML.  Updates in real time.

Error if not in `markdown-mode' or `gfm-mode'."
  (interactive)
  (if (derived-mode-p 'markdown-mode 'gfm-mode)
      (native-md-preview-mode (if native-md-preview-mode -1 1))
    (user-error "Current buffer is not in markdown-mode or gfm-mode")))

(provide 'native-md-preview)
;;; native-md-preview.el ends here
