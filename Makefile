EMACS ?= emacs
CARGO ?= cargo
PACKAGE_LINT_PATH ?= $(HOME)/.emacs.d/straight/repos/package-lint
COMPAT_PATH ?= $(HOME)/.emacs.d/straight/repos/compat

.PHONY: check compile test checkdoc package-lint helper-check helper-test clean

check: compile test checkdoc package-lint helper-check

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile ytm-radio.el test/ytm-radio-test.el

test:
	$(EMACS) -Q --batch -L . -l ytm-radio.el -l test/ytm-radio-test.el -f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch -L . --eval "(progn (require 'checkdoc) (dolist (file '(\"ytm-radio.el\")) (with-current-buffer (find-file-noselect file) (let ((checkdoc-create-error-function #'error)) (checkdoc-current-buffer t)))))"

package-lint:
	@if [ ! -f "$(PACKAGE_LINT_PATH)/package-lint.el" ]; then echo "package-lint unavailable at $(PACKAGE_LINT_PATH)" >&2; exit 1; fi
	$(EMACS) -Q --batch -L $(COMPAT_PATH) -L $(PACKAGE_LINT_PATH) -l package-lint --eval "(setq package-lint-batch-fail-on-warnings t)" -f package-lint-batch-and-exit ytm-radio.el

helper-check:
	$(CARGO) fmt --manifest-path helper/Cargo.toml -- --check
	$(CARGO) clippy --manifest-path helper/Cargo.toml -- -D warnings
	$(MAKE) helper-test
	$(CARGO) build --manifest-path helper/Cargo.toml

helper-test:
	$(CARGO) test --manifest-path helper/Cargo.toml

clean:
	rm -f *.elc test/*.elc
	$(CARGO) clean --manifest-path helper/Cargo.toml
