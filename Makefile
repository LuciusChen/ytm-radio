EMACS ?= emacs
CARGO ?= cargo
PACKAGE_LINT_PATH ?= $(HOME)/.emacs.d/straight/repos/package-lint
COMPAT_PATH ?= $(HOME)/.emacs.d/straight/repos/compat
IMAGE_SLICE_PATH ?= $(HOME)/repos/image-slice
ELISP_LOAD_PATH = -L . -L $(IMAGE_SLICE_PATH)

.PHONY: check check-image-slice compile test checkdoc package-lint helper-check helper-test clean

# helper-check runs before test so the Elisp helper-contract tests find a
# freshly built debug helper instead of skipping.
check: compile helper-check test checkdoc package-lint

check-image-slice:
	@if [ ! -f "$(IMAGE_SLICE_PATH)/image-slice.el" ]; then echo "image-slice unavailable at $(IMAGE_SLICE_PATH); set IMAGE_SLICE_PATH" >&2; exit 1; fi

compile: check-image-slice
	$(EMACS) -Q --batch $(ELISP_LOAD_PATH) -f batch-byte-compile ytm-radio.el test/package-lint-local-dependencies.el test/ytm-radio-test.el

test: check-image-slice
	$(EMACS) -Q --batch $(ELISP_LOAD_PATH) -l ytm-radio.el -l test/ytm-radio-test.el -f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch $(ELISP_LOAD_PATH) --eval "(progn (require 'checkdoc) (with-current-buffer (find-file-noselect \"ytm-radio.el\") (let ((checkdoc-create-error-function #'error)) (checkdoc-current-buffer t))))"

package-lint:
	@if [ ! -f "$(PACKAGE_LINT_PATH)/package-lint.el" ]; then echo "package-lint unavailable at $(PACKAGE_LINT_PATH)" >&2; exit 1; fi
	YTM_RADIO_IMAGE_SLICE_FILE="$(IMAGE_SLICE_PATH)/image-slice.el" $(EMACS) -Q --batch -L $(COMPAT_PATH) -L $(PACKAGE_LINT_PATH) -l test/package-lint-local-dependencies.el -l package-lint --eval "(setq package-lint-batch-fail-on-warnings t)" -f package-lint-batch-and-exit ytm-radio.el

helper-check:
	$(CARGO) fmt --manifest-path helper/Cargo.toml -- --check
	$(CARGO) clippy --manifest-path helper/Cargo.toml --locked -- -D warnings
	$(MAKE) helper-test
	$(CARGO) build --manifest-path helper/Cargo.toml --locked

helper-test:
	$(CARGO) test --manifest-path helper/Cargo.toml --locked

clean:
	rm -f *.elc test/*.elc
	$(CARGO) clean --manifest-path helper/Cargo.toml
