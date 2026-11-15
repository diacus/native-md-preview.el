#!/bin/sh
# Run the native-md-preview test suite headless.
#
# 1. Byte-compiles the package (compile errors fail the run)
# 2. Runs every ert-deftest in test/native-md-preview-test.el
#
# Skipped when pandoc or markdown-mode is unavailable.

set -eu
cd "$(dirname "$0")/.."

MMD=$(ls -d "${MARKDOWN_MODE_DIR:-}" ~/.emacs.d/elpa/markdown-mode-* 2>/dev/null | sort | tail -1 || true)
if [ -z "$MMD" ]; then
    echo "error: markdown-mode not found (set MARKDOWN_MODE_DIR)" >&2
    exit 1
fi

emacs -Q --batch -L "$MMD" -L . -f batch-byte-compile native-md-preview.el

emacs -Q --batch -L "$MMD" -L . -l test/native-md-preview-test \
      -f ert-run-tests-batch-and-exit
