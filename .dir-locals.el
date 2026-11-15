;;; Directory local variables (flycheck elisp checker needs the repo
;;; root on the load path to resolve `(require 'native-md-preview)'
;;; from test/).

((nil
  . ((projectile-project-test-cmd . "./test/run-tests.sh")))
 (emacs-lisp-mode
  . ((flycheck-emacs-lisp-load-path
      . (:eval (list (locate-dominating-file
                      (or buffer-file-name default-directory)
                      "native-md-preview.el"))))
     (indent-tabs-mode . nil))))
