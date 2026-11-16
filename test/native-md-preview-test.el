;;; native-md-preview-test.el --- Tests for native-md-preview -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Diacus Magnuz

;; Author: Diacus Magnuz <diacus.magnuz@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

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

;; ERT test suite for `native-md-preview'.  Runs headless with:
;;
;;   `emacs' -Q --batch -L . -l test/native-md-preview-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; See test/run-tests.sh.
;;
;; Batch-mode notes (no redisplay): window-scroll-functions never fire,
;; so the scroll-sync tests invoke the hook functions directly.
;; `display-buffer' DOES work in batch (pop-up-window splits the
;; terminal frame's single window), and kill-buffer-hook fires
;; normally, so lifecycle tests run unmodified.

;;; Code:

(require 'ert)
(require 'native-md-preview)

(defconst native-md-preview-test--pandoc (executable-find "pandoc")
  "Path to pandoc, or nil when unavailable.")

(defun native-md-preview-test--kill-buffers ()
  "Kill every buffer produced by a test, plus the preview buffers."
  (dolist (buf (buffer-list))
    (when (or (string-prefix-p "*native-md-preview" (buffer-name buf))
              (string-prefix-p "nmdp-test" (buffer-name buf)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(defun native-md-preview-test--source-buffer (name content &optional file)
  "Create a markdown-mode test buffer NAME holding CONTENT.
When FILE is non-nil, make the buffer visit a unique temp file and
return the buffer visiting it.

The buffer is displayed in the selected window: this mirrors real
usage (the source buffer is visible when previewing), and without it
`display-buffer' and window-dependent code cannot be exercised in a
batch Emacs."
  (if file
      (let ((fname (make-temp-file "nmdp-test-" nil ".md"))
            (buf nil))
        (with-temp-file fname (insert content))
        (setq buf (find-file-noselect fname))
        (rename-buffer name)
        (set-window-buffer (selected-window) buf)
        buf)
    (with-current-buffer (get-buffer-create name)
      (erase-buffer)
      (insert content)
      (markdown-mode)
      (set-window-buffer (selected-window) (current-buffer))
      (current-buffer))))

(defun native-md-preview-test--previews ()
  "List live native-md-preview buffers."
  (seq-filter (lambda (b) (string-prefix-p "*native-md-preview"
                                           (buffer-name b)))
              (buffer-list)))

(defun native-md-preview-test--in-hooks (src symbol hook)
  "Whether SYMBOL is in SRC's buffer-local HOOK."
  (memq symbol (buffer-local-value hook src)))

;; NOTE on toggle calls: `native-md-preview--enable' ends with
;; (select-window source-window), which switches the current buffer to
;; that window's buffer.  `with-current-buffer' only restores the
;; buffer when its body finishes, so every toggle call and every
;; assertion must be wrapped SEPARATELY; never read state in the same
;; `with-current-buffer' body right after a toggle.

(defmacro native-md-preview-test--with-source (var &rest body)
  "Bind VAR to a fresh file-less source buffer, run BODY, clean up."
  (declare (indent 1))
  `(let ((,var nil))
     (unwind-protect
         (progn
           (setq ,var (native-md-preview-test--source-buffer
                       (format "nmdp-test-src-%d" (random most-positive-fixnum))
                       "# Heading\n\nSome *body* text.\n"))
           ,@body)
       (native-md-preview-test--kill-buffers))))

;;; Buffer names

(ert-deftest native-md-preview/buffer-name-file-buffer ()
  (let ((dir (make-temp-file "nmdp-test-dir" t)))
    (unwind-protect
        (with-current-buffer (find-file-noselect (expand-file-name "some.md" dir))
          (should (equal (native-md-preview--buffer-name)
                         "*native-md-preview:some.md*"))
          (kill-buffer))
      (delete-directory dir t))))

(ert-deftest native-md-preview/buffer-name-fileless-buffer ()
  (native-md-preview-test--with-source src
    (with-current-buffer src
      (should (equal (native-md-preview--buffer-name)
                     (format "*native-md-preview:%s*" (buffer-name src)))))))

(ert-deftest native-md-preview/buffer-name-custom-prefix ()
  (let ((native-md-preview-buffer-name-prefix "*xyzzy"))
    (native-md-preview-test--with-source src
      (with-current-buffer src
        (should (equal (native-md-preview--buffer-name)
                       (format "*xyzzy:%s*" (buffer-name src))))))))

;;; HTML conversion and rendering

(ert-deftest native-md-preview/to-html-pandoc-converts ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src
      (erase-buffer)
      (insert "# Nmdp Title\n\nSome text.\n")
      (let ((html (native-md-preview--to-html)))
        (should (string-prefix-p "<!DOCTYPE html>" html))
        (should (string-match-p "<h1" html))
        (should (string-match-p "Nmdp Title" html))))))

(ert-deftest native-md-preview/to-html-no-preview-buffers-left ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src
      (native-md-preview--to-html))
    (should-not (native-md-preview-test--previews))))

(ert-deftest native-md-preview/render-html-inserts-document ()
  (with-temp-buffer
    (native-md-preview--render-html
     "<!DOCTYPE html><html><body><p><b>Bold</b> and plain</p></body></html>")
    ;; shr wraps text at the fill column; match words, not phrases
    (should (string-match-p "Bold" (buffer-string)))
    (should (string-match-p "plain" (buffer-string)))))

(ert-deftest native-md-preview/render-html-keeps-position ()
  (with-temp-buffer
    (insert "placeholder that gets erased")
    (native-md-preview--render-html
     "<html><body><p>rendered</p></body></html>")
    ;; The mode is meant to be called with the buffer shown, and enables
    ;; a scroll sync; rendering must leave point at the top.
    (should (= (point) (point-min)))
    (should (string-match-p "rendered" (buffer-string)))))

;;; Syntax highlighting

;; Face resolution is theme-dependent; in batch no theme is loaded and
;; font-lock faces report an `unspecified-fg' foreground sentinel.
;; Tests stub explicit colors through the global face spec, which
;; works headless, and restore whatever was there before (possibly the
;; sentinel symbol itself, which `set-face-attribute' accepts back
;; verbatim).

(defun native-md-preview-test--with-faces (spec body-thunk)
  "Stub face foregrounds from SPEC while calling BODY-THUNK.
SPEC is a list of (FACE . COLOR) pairs.  The previous foreground of
each FACE is restored afterwards, whatever its type."
  (let ((saved nil))
    (unwind-protect
        (progn
          (dolist (entry spec)
            (let ((face (car entry)))
              (push (cons face (face-attribute face :foreground nil t))
                    saved))
            (set-face-attribute (car entry) nil :foreground (cdr entry)))
          (funcall body-thunk))
      (dolist (entry saved)
        (set-face-attribute (car entry) nil :foreground (cdr entry))))))

(ert-deftest native-md-preview/highlight-code-tokens-injects-styles ()
  (native-md-preview-test--with-faces
   '((font-lock-keyword-face . "#569cd6")
     (font-lock-comment-face . "#6a9955"))
   (lambda ()
     (should
      (equal
       (native-md-preview--highlight-code-tokens
        "foo <span class=\"kw\">def</span> bar <span class=\"co\"># c</span>"
        (native-md-preview--token-styles))
       (concat "foo <span class=\"kw\" style=\"color:#569cd6\">def</span>"
               " bar <span class=\"co\" style=\"color:#6a9955\"># c</span>"))))))

(ert-deftest native-md-preview/highlight-code-tokens-unknown-class-untouched ()
  (native-md-preview-test--with-faces
   '((font-lock-keyword-face . "#569cd6"))
   (lambda ()
     (should
      (equal
       (native-md-preview--highlight-code-tokens
        "<span class=\"zz\">x</span><span class=\"math inline\">y</span>"
        (native-md-preview--token-styles))
       "<span class=\"zz\">x</span><span class=\"math inline\">y</span>"))
     ;; The --no-highlight shape: no token spans at all
     (should
      (equal
       (native-md-preview--highlight-code-tokens
        "<pre class=\"python\"><code>x = 1</code></pre>"
        (native-md-preview--token-styles))
       "<pre class=\"python\"><code>x = 1</code></pre>")))))

(ert-deftest native-md-preview/highlight-code-tokens-adjacent-spans ()
  (native-md-preview-test--with-faces
   '((font-lock-string-face . "#ce9178")
     (font-lock-constant-face . "#4fc1ff"))
   (lambda ()
     (should
      (equal
       (native-md-preview--highlight-code-tokens
        "<span class=\"ss\">f\"</span><span class=\"dv\">1</span>"
        (native-md-preview--token-styles))
       (concat "<span class=\"ss\" style=\"color:#ce9178\">f\"</span>"
               "<span class=\"dv\" style=\"color:#4fc1ff\">1</span>"))))))

(ert-deftest native-md-preview/face-color-hex-and-named ()
  (native-md-preview-test--with-faces
   '((font-lock-keyword-face . "#c586c0")
     (font-lock-string-face . "orchid"))
   (lambda ()
     (should (equal (native-md-preview--face-color 'font-lock-keyword-face)
                    "#c586c0"))
     (let ((rgb (native-md-preview--face-color 'font-lock-string-face)))
       (should (stringp rgb))
       (should (string-match-p "#[0-9a-f]\\{6\\}" rgb))))))

(ert-deftest native-md-preview/face-color-unspecified-degrades ()
  (native-md-preview-test--with-faces
   '((font-lock-keyword-face . unspecified))
   (lambda ()
     (should (null (native-md-preview--face-color 'font-lock-keyword-face))))))

(defconst native-md-preview-test--python-doc
  "```python\nimport os\ndef foo(x):  # note\n    return \"s\" + str(1.5)\n```\n"
  "Markdown document with a python fence for highlighting tests.")

(ert-deftest native-md-preview/to-html-highlights-fenced-code ()
  (skip-unless native-md-preview-test--pandoc)
  ;; In batch no theme is loaded and every font-lock face resolves to
  ;; an unspecified foreground, which previews as unstyled; stub the
  ;; colors for the classes pandoc emits for this document.
  (native-md-preview-test--with-faces
   '((font-lock-keyword-face . "#569cd6")
     (font-lock-comment-face . "#6a9955")
     (font-lock-constant-face . "#4fc1ff"))
   (lambda ()
     (native-md-preview-test--with-source src
       (with-current-buffer src
         (erase-buffer)
         (insert native-md-preview-test--python-doc)
         (let ((html (native-md-preview--to-html)))
           (should (string-match-p
                    "<span class=\"kw\" style=\"color:#[0-9a-f]\\{6\\}\">def</span>"
                    html))
           (should (string-match-p
                    "<span class=\"co\" style=\"color:#[0-9a-f]\\{6\\}\">"
                    html))
           (should (string-match-p
                    "<span class=\"fl\" style=\"color:#[0-9a-f]\\{6\\}\">"
                    html))
           ;; Per-line spans and sourceCode containers stay unstyled
           (should-not (string-match-p
                        "<span id=\"cb[0-9]+-[0-9]+\" style=" html))
           (should-not (string-match-p
                        "<span class=\"sourceCode\" style=" html))
           (should-not (string-match-p
                        "class=\"sourceCode python\" style=" html))))))))

(ert-deftest native-md-preview/to-html-plain-fence-unstyled ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-faces
   '((font-lock-keyword-face . "#569cd6"))
   (lambda ()
     (native-md-preview-test--with-source src
       (with-current-buffer src
         (erase-buffer)
         (insert "```\nx = 1\n```\n")
         (should-not (string-match-p
                      "style=\"color:"
                      (native-md-preview--to-html))))))))

(ert-deftest native-md-preview/to-html-styles-when-disabled ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-faces
   '((font-lock-keyword-face . "#569cd6"))
   (lambda ()
     (native-md-preview-test--with-source src
       (with-current-buffer src
         (erase-buffer)
         (insert native-md-preview-test--python-doc)
         (should-not
          (string-match-p
           "style=\"color:"
           (let ((native-md-preview-token-faces nil))
             (native-md-preview--to-html)))))))))

;;; Tables

(ert-deftest native-md-preview/style-table-headers-injects-bg ()
  (should
   (equal
    (native-md-preview--style-table-headers "<th>Name</th>" "#ebebeb")
    "<th style=\"background-color:#ebebeb\">Name</th>"))
  (should
   (equal
    (native-md-preview--style-table-headers
     "<th>A</th><th>B</th>" "#ebebeb")
    (concat "<th style=\"background-color:#ebebeb\">A</th>"
            "<th style=\"background-color:#ebebeb\">B</th>"))))

(ert-deftest native-md-preview/style-table-headers-extends-style ()
  ;; pandoc emits text-align styles on header cells
  (should
   (equal
    (native-md-preview--style-table-headers
     "<th style=\"text-align: center;\">C</th>" "#ebebeb")
    "<th style=\"text-align: center;background-color:#ebebeb\">C</th>")))

(ert-deftest native-md-preview/collapse-tables-bare-table ()
  (should
   (equal
    (native-md-preview--collapse-tables
     "<table><tr><td>1</td></tr></table>" t)
    (concat "<table style=\"border-collapse: collapse\">"
            "<tr><td>1</td></tr></table>"))))

(ert-deftest native-md-preview/collapse-tables-extends-style ()
  ;; Existing styles (pandoc grid/narrow tables) must not be clobbered
  (should
   (equal
    (native-md-preview--collapse-tables "<table style=\"width: 56%\">" t)
    "<table style=\"border-collapse: collapse;width: 56%\">")))

(ert-deftest native-md-preview/collapse-tables-leaves-collapsed-untouched ()
  (should
   (equal
    (native-md-preview--collapse-tables
     "<table style=\"border-collapse: collapse\">" t)
    "<table style=\"border-collapse: collapse\">")))

(ert-deftest native-md-preview/collapse-tables-noop-when-disabled ()
  (dolist (tag (list "<table>"
                     "<table style=\"width: 56%\">"
                     "<table style=\"border-collapse: collapse\">"))
    (should (equal (native-md-preview--collapse-tables tag nil) tag))))

(ert-deftest native-md-preview/collapse-tables-ignores-other-tags ()
  (dolist (html (list "<td>x</td>" "<tablestyle>x</tablestyle>"
                      "</table>" "<span class=\"kw\">def</span>"))
    (should (equal (native-md-preview--collapse-tables html t) html))))

(ert-deftest native-md-preview/collapse-tables-multiple-tables ()
  (should
   (equal
    (native-md-preview--collapse-tables
     "<table></table>text<table></table>" t)
    (concat "<table style=\"border-collapse: collapse\"></table>"
            "text"
            "<table style=\"border-collapse: collapse\"></table>"))))

(ert-deftest native-md-preview/render-html-table-rules-when-shr-renderer ()
  (let ((native-md-preview-table-renderer 'shr)
        (native-md-preview-table-horizontal-line ?─)
        (native-md-preview-table-vertical-line ?│)
        (native-md-preview-table-corner ?┼))
    (with-temp-buffer
      (native-md-preview--render-html
       "<!DOCTYPE html><html><body>
<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>
</body></html>")
      (should (string-match-p "─" (buffer-string)))
      (should (string-match-p "│" (buffer-string)))
      (should (string-match-p "┼" (buffer-string)))))
  ;; The none setting restores the pre-styling line-free rendering
  (let ((native-md-preview-table-renderer 'shr)
        (native-md-preview-table-horizontal-line nil))
    (with-temp-buffer
      (native-md-preview--render-html
       "<!DOCTYPE html><html><body>
<table><tr><td>a</td><td>b</td></tr></table>
</body></html>")
      (should-not (string-match-p "─" (buffer-string))))))

(ert-deftest native-md-preview/render-html-table-boxes-grid ()
  (with-temp-buffer
    (native-md-preview--render-html
     "<!DOCTYPE html><html><body>
<table><tr><th>Name</th><th>Age</th></tr>
<tr><td>Alice</td><td>25</td></tr></table>
</body></html>")
    (let ((text (buffer-string)))
      (should (string-match-p "┌" text))
      (should (string-match-p "│ Name" text))
      (should (string-match-p "├" text))
      (should (string-match-p "└" text))
      (should (string-match-p "Alice" text))
      ;; No nested double boxing
      (should-not (string-match-p "││" text)))))

(defconst native-md-preview-test--table-doc
  "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
  "Markdown document with a GFM pipe table for collapse tests.")

(ert-deftest native-md-preview/to-html-collapses-gfm-table ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src
      (erase-buffer)
      (insert native-md-preview-test--table-doc)
      (let ((native-md-preview-table-collapse t))
        (should (string-match-p
                 "<table style=\"[^\"]*border-collapse: collapse\""
                 (native-md-preview--to-html))))
      (let ((native-md-preview-table-collapse nil))
        (should (string-match-p
                 "<table>"
                 (native-md-preview--to-html)))))))

;; Buffer-local values must be honored even though the transform runs
;; inside temp buffers
(ert-deftest native-md-preview/to-html-collapses-buffer-local-option ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src
      (erase-buffer)
      (insert native-md-preview-test--table-doc)
      (setq-local native-md-preview-table-collapse t)
      (should (string-match-p
               "border-collapse: collapse"
               (native-md-preview--to-html))))))

(ert-deftest native-md-preview/style-table-headers-ignores-others ()
  (dolist (html (list "<td>a</td>" "<thead>" "<tr>"
                      "<th style=\"background-color:#ccc\">x</th>"))
    (should (equal (native-md-preview--style-table-headers html "#ebebeb")
                   html)))
  ;; nil BG: identity
  (should (equal (native-md-preview--style-table-headers "<th>A</th>" nil)
                 "<th>A</th>")))

(defun native-md-preview-test--with-face-background (face color body-thunk)
  "Stub the :background of FACE with COLOR while calling BODY-THUNK.
The previous background is restored afterwards, whatever its type."
  (let ((saved (face-attribute face :background nil t)))
    (unwind-protect
        (progn
          (set-face-attribute face nil :background color)
          (funcall body-thunk))
      (set-face-attribute face nil :background saved))))

(ert-deftest native-md-preview/face-color-background-attribute ()
  (native-md-preview-test--with-face-background
   'header-line "#e5e5e5"
   (lambda ()
     (should (equal (native-md-preview--face-color 'header-line :background)
                    "#e5e5e5")))))

;; Buffer-local header face values must be honored even though the
;; transform runs inside temp buffers
(ert-deftest native-md-preview/to-html-styles-gfm-table-headers ()
  (skip-unless native-md-preview-test--pandoc)
  ;; Headers are unshaded by default; the test enables the shading
  (let ((native-md-preview-table-header-face 'header-line))
    (native-md-preview-test--with-face-background
     'header-line "#e5e5e5"
     (lambda ()
       (native-md-preview-test--with-source src
         (with-current-buffer src
           (erase-buffer)
           (insert native-md-preview-test--table-doc)
           (should (string-match-p
                    "<th[^>]*style=\"[^\"]*background-color:#e5e5e5\""
                    (native-md-preview--to-html)))))))))

(ert-deftest native-md-preview/table-wrap-breaks-lines ()
  (should
   (equal (native-md-preview--table-wrap "abcdefghij klmnopqrstuvwxyz" 10)
          '("abcdefghij" "klmnopqrst" "uvwxyz")))
  ;; short line passed through
  (should (equal (native-md-preview--table-wrap "abc" 10) '("abc")))
  ;; breaking at spaces keeps words whole
  (should
   (equal (native-md-preview--table-wrap "aa bbb cc" 5) '("aa" "bbb" "cc"))))

(ert-deftest native-md-preview/table-fit-wraps-to-avail ()
  (let* ((grid (list
                (list (list (list "Variable") nil nil nil)
                      (list (list "Values") nil nil nil)
                      (list (list "Effect") nil nil nil))
                (list (list (list "g:kb_layout") nil nil nil)
                      (list (list "'es', 'latam'") nil nil nil)
                      (list (list "applies the Spanish or Latin American layout mappings on load") nil nil nil)))))
    ;; a column as wide as the whole budget wraps its cells
    (let* ((fit (native-md-preview--table-fit grid [10 10 58] 20))
           (grid (car fit))
           (widths (cdr fit)))
      (should (<= (apply #'+ (append widths nil)) 16))
      (should (> (length (car (nth 2 (nth 1 grid)))) 1))
      ;; header, align and bg survive wrapping
      (should (null (nth 1 (nth 0 (nth 0 grid))))))))
;; Headers ship unshaded: the default defcustom leaves the cells bare
(ert-deftest native-md-preview/to-html-gfm-table-headers-unshaded ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src
      (erase-buffer)
      (insert native-md-preview-test--table-doc)
      (should-not (string-match-p
                   "background-color"
                   (native-md-preview--to-html))))))

(ert-deftest native-md-preview/flatten-tables-removes-section-wrappers ()
  (should
   (equal
    (native-md-preview--flatten-tables
     "<table><thead><tr><th>A</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>")
    "<table><tr><th>A</th></tr><tr><td>1</td></tr></table>"))
  ;; Content without wrappers is untouched
  (should
   (equal
    (native-md-preview--flatten-tables "<tr><td>1</td></tr>")
    "<tr><td>1</td></tr>")))

(ert-deftest native-md-preview/to-html-gfm-table-unsectioned ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src
      (erase-buffer)
      (insert native-md-preview-test--table-doc)
      (let ((html (native-md-preview--to-html)))
        (should (string-match-p "<tr>" html))
        (should-not (string-match-p "</?\\(thead\\|tbody\\)>" html))))))

;;; Enable / preview buffers

(ert-deftest native-md-preview/enable-creates-per-document-preview ()
  (skip-unless native-md-preview-test--pandoc)
  (let ((src1 nil) (src2 nil))
    (unwind-protect
        (progn
          (setq src1 (native-md-preview-test--source-buffer
                      "nmdp-test-one" "# Doc one\n")
                src2 (native-md-preview-test--source-buffer
                      "nmdp-test-two" "# Doc two\n"))
          (with-current-buffer src1 (native-md-preview-toggle))
          (with-current-buffer src2 (native-md-preview-toggle))
          (let ((prev1 (buffer-local-value 'native-md-preview--preview-buffer src1))
                (prev2 (buffer-local-value 'native-md-preview--preview-buffer src2)))
            (should (buffer-live-p prev1))
            (should (buffer-live-p prev2))
            (should-not (equal prev1 prev2))
            (should (equal (buffer-name prev1)
                           (native-md-preview--buffer-name src1)))
            (should (equal (buffer-name prev2)
                           (native-md-preview--buffer-name src2)))
            ;; Back-references are set on both sides
            (should (eq (buffer-local-value 'native-md-preview--source-buffer prev1)
                        src1))
            ;; Rendered content lands in the preview buffer (shr may
            ;; wrap text across lines, so match words, not phrases)
            (with-current-buffer prev1
              (should (string-match-p "Doc" (buffer-string)))
              (should (string-match-p "one" (buffer-string))))))
      (native-md-preview-test--kill-buffers))))

(ert-deftest native-md-preview/enable-sets-mode-and-hooks ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src
      (native-md-preview-toggle))
    (with-current-buffer src
      (should (eq native-md-preview-mode t))
      (should (native-md-preview-test--in-hooks
               src 'native-md-preview--after-change 'after-change-functions))
      (should (native-md-preview-test--in-hooks
               src 'native-md-preview--sync-scroll-hook 'window-scroll-functions))
      ;; The preview buffer gets the reverse-scroll hook and a back-reference
      (let ((prev (buffer-local-value 'native-md-preview--preview-buffer src)))
        (should (native-md-preview-test--in-hooks
                 prev 'native-md-preview--reverse-sync-scroll-hook
                 'window-scroll-functions))))))

(ert-deftest native-md-preview/enable-rejects-non-markdown ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (should-error (native-md-preview-toggle))))

;;; Disable / cleanup

(ert-deftest native-md-preview/disable-removes-hooks-and-state ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src (native-md-preview-toggle))
    (with-current-buffer src (native-md-preview-toggle))
    (with-current-buffer src
      (should (null native-md-preview-mode))
      (should (null (native-md-preview-test--in-hooks
                     src 'native-md-preview--after-change
                     'after-change-functions)))
      (should (null (native-md-preview-test--in-hooks
                     src 'native-md-preview--sync-scroll-hook
                     'window-scroll-functions)))
      (should (null native-md-preview--preview-buffer))
      (should (null native-md-preview--preview-window))
      (should (null (native-md-preview-test--previews))))))

(ert-deftest native-md-preview/kill-source-kills-preview ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src (native-md-preview-toggle))
    (with-current-buffer src
      (let ((prev native-md-preview--preview-buffer))
        (should (buffer-live-p prev))
        ;; Kill the source from the outside; kill-buffer-hook must clean up
        (kill-buffer src)
        (should-not (buffer-live-p prev))))))

(ert-deftest native-md-preview/kill-preview-clears-source-state ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src (native-md-preview-toggle))
    (with-current-buffer src
      (with-current-buffer native-md-preview--preview-buffer (kill-buffer)))
    (with-current-buffer src
      (should (null native-md-preview-mode))
      (should (null native-md-preview--preview-buffer))
      (should (null native-md-preview--preview-window))
      (should (null (native-md-preview-test--in-hooks
                     src 'native-md-preview--after-change
                     'after-change-functions))))))

(ert-deftest native-md-preview/refresh-schedules-and-cancels-timer ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src (native-md-preview-toggle))
    (with-current-buffer src
      (insert "more text")
      ;; after-change-functions don't run without redisplay; call the
      ;; hook function directly.
      (native-md-preview--after-change)
      (should (timerp native-md-preview--timer)))
    (with-current-buffer src (native-md-preview-toggle))
    (with-current-buffer src
      (should-not (timerp native-md-preview--timer)))))

;;; Scroll synchronization

(defun native-md-preview-test--long-doc (lines)
  "Build a markdown document with LINES filler lines."
  (mapconcat (lambda (i) (format "Line %d: word word word\n" i))
             (number-sequence 1 lines) ""))

(ert-deftest native-md-preview/sync-scroll-follows-source ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src
      (erase-buffer)
      (insert (native-md-preview-test--long-doc 200))
      (native-md-preview-mode 1))
    (with-current-buffer src
      (let* ((prev native-md-preview--preview-buffer)
             (prev-win native-md-preview--preview-window))
        (should (window-live-p prev-win))
        ;; Jump to the middle of the source and sync manually
        (with-selected-window (get-buffer-window src)
          (goto-char (point-min))
          (forward-line 90)
          (set-window-start (selected-window) (point)))
        ;; window-scroll-functions need redisplay to fire; call directly
        (native-md-preview--sync-scroll (get-buffer-window src))
        ;; The preview window's start must have moved away from the top
        (should (> (window-start prev-win) 1))))))

(ert-deftest native-md-preview/reverse-sync-follows-preview ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src
      (erase-buffer)
      (insert (native-md-preview-test--long-doc 200))
      (native-md-preview-mode 1))
    (with-current-buffer src
      (let* ((prev native-md-preview--preview-buffer)
             (prev-win native-md-preview--preview-window)
             (src-win (get-buffer-window src)))
        ;; Scroll the preview window towards its middle
        (with-current-buffer prev
          (with-selected-window prev-win
            (goto-char (point-min))
            (forward-line 60)
            (set-window-start (selected-window) (point))))
        ;; Call the reverse-sync hook directly
        (with-current-buffer prev
          (native-md-preview--reverse-sync-scroll prev-win))
        ;; The source window's start must have moved away from the top
        (should (> (window-start src-win) 1))))))

(ert-deftest native-md-preview/refresh-keeps-preview-anchored ()
  (skip-unless native-md-preview-test--pandoc)
  (native-md-preview-test--with-source src
    (with-current-buffer src
      (erase-buffer)
      (insert (native-md-preview-test--long-doc 200))
      (native-md-preview-mode 1))
    (with-current-buffer src
      (let* ((prev native-md-preview--preview-buffer)
             (prev-win native-md-preview--preview-window)
             (src-win (get-buffer-window src))
             (prev-line-before nil))
        (should (window-live-p prev-win))
        ;; Scroll the source towards the middle; batch hooks don't fire,
        ;; so establish the baseline sync directly.
        (with-selected-window src-win
          (goto-char (point-min))
          (forward-line 90)
          (set-window-point src-win (point))
          (set-window-start src-win (point)))
        (native-md-preview--sync-scroll src-win)
        (setq prev-line-before
              (with-current-buffer prev
                (line-number-at-pos (window-start prev-win))))
        (should (> prev-line-before 1))
        ;; Edit the buffer (join-like modification) and re-render the
        ;; way the debouncer does: the preview must stay anchored near
        ;; the source's view, NOT reset to the top.
        (with-current-buffer src
          (goto-char (point-min))
          (forward-line 5)
          (insert "joined content\n"))
        (native-md-preview--refresh src prev)
        (let ((prev-line-after
               (with-current-buffer prev
                 (line-number-at-pos (window-start prev-win)))))
          (should (> prev-line-after 1))
          ;; Re-anchoring follows the (unscrolled) source view; it may
          ;; drift a line or two with the content change, but it must
          ;; stay in the source's neighborhood.
          (should (< (abs (- prev-line-after prev-line-before))
                     (+ 2 (/ prev-line-before 8)))))))))

;;; Provide

(provide 'native-md-preview-test)
;;; native-md-preview-test.el ends here
