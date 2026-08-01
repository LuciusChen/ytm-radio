;;; package-lint-local-dependencies.el --- Register local lint packages -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Register the separately checked out image-slice package after package.el
;; initializes.  package-lint otherwise rejects a new dependency until an
;; external package archive has indexed its first release.  Remove this helper
;; once the lint environment loads an archive index containing image-slice.

;;; Code:

(require 'package)

(defvar ytm-radio-test--image-slice-package-descriptor nil
  "Local image-slice descriptor used by package-lint tests.")

(defun ytm-radio-test--register-image-slice-package (&rest _arguments)
  "Register the local image-slice descriptor in `package-alist'."
  (setq package-alist (assq-delete-all 'image-slice package-alist))
  (push (list 'image-slice
              ytm-radio-test--image-slice-package-descriptor)
        package-alist))

(let ((file (getenv "YTM_RADIO_IMAGE_SLICE_FILE")))
  (unless (and file (file-readable-p file))
    (error "Local image-slice package file is unavailable: %S" file))
  (with-temp-buffer
    (insert-file-contents file)
    (setq ytm-radio-test--image-slice-package-descriptor
          (package-buffer-info))))

;; `package-lint-batch-and-exit' calls `package-initialize', which rebuilds
;; `package-alist', so the descriptor must be registered afterward.
(advice-add 'package-initialize
            :after #'ytm-radio-test--register-image-slice-package)

(provide 'package-lint-local-dependencies)
;;; package-lint-local-dependencies.el ends here
