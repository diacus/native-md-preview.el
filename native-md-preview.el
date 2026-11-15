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
;;
;; Enable with `native-md-preview-mode' or `native-md-preview-toggle'
;; from a `markdown-mode' or `gfm-mode' buffer.
;;
;; External dependency: a Markdown processor such as pandoc on the
;; PATH, configured through `markdown-command'.

;;; Code:

(require 'markdown-mode)
(require 'shr)

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

(defun native-md-preview--to-html ()
  "Convert current markdown buffer to HTML string.
Wraps in minimal HTML structure for proper rendering, including a
base element pointing at the buffer's location, so that shr expands
relative image paths and links against the document's directory."
  (let ((content (buffer-string))
        (cmd (if (boundp 'markdown-command) markdown-command "pandoc"))
        (base (native-md-preview--base-href)))
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
              (let ((html (buffer-string)))
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
refresh, leaking buffers."
  (let ((inhibit-read-only t))
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
