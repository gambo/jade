;;; jade-debugger.el --- Jade debugger               -*- lexical-binding: t; -*-

;; Copyright (C) 2016  Nicolas Petton

;; Author: Nicolas Petton <nicolas@petton.fr>
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'seq)
(require 'map)
(require 'jade-inspector)
(require 'jade-repl)
(require 'jade-render)

(defgroup jade-debugger nil
  "JavaScript debugger"
  :prefix "jade-debugger-"
  :group 'jade)

(defcustom jade-debugger-major-mode
  #'js-mode
  "Major mode used in debugger buffers."
  :group 'jade-debugger)

(defvar jade-debugger-buffer nil "Buffer used for debugging JavaScript sources.")

(defvar jade-debugger-frames nil "List of frames of the current debugger context.")
(make-variable-buffer-local 'jade-debugger-frames)

(defconst jade-debugger-fringe-arrow-string
  #("." 0 1 (display (left-fringe right-triangle)))
  "Used as an overlay's before-string prop to place a fringe arrow.")

(declare 'jade-backend-debugger-get-script-source)

(defun jade-debugger-paused (backend frames)
  (let ((top-frame (car frames)))
   (jade-backend-get-script-source backend
                                   top-frame
                                   (lambda (source)
                                     (let ((jade-backend backend))
                                       (jade-debugger-get-buffer-create frames backend jade-connection)
                                       (jade-debugger-switch-to-frame
                                        top-frame
                                        (map-nested-elt source '(result scriptSource))))))))

(defun jade-debugger-resumed (&rest _args)
  (let ((buf (jade-debugger-get-buffer)))
    (when buf
      (set-marker overlay-arrow-position nil (current-buffer))
      (remove-overlays))))

(defun jade-debugger-switch-to-frame (frame source)
  (jade-debugger-debug-frame frame source)
  (switch-to-buffer (jade-debugger-get-buffer))
  (jade-debugger-locals-maybe-refresh))

(defun jade-debugger-debug-frame (frame source)
  (let* ((location (map-elt frame 'location))
         (line (map-elt location 'lineNumber))
         (column (map-elt location 'columnNumber))
         (inhibit-read-only t))
    (with-current-buffer (jade-debugger-get-buffer)
      (unless (string= (buffer-substring-no-properties (point-min) (point-max))
                       source)
        (erase-buffer)
        (insert source))
      (goto-line (1+ line))
      (forward-char column)
      (jade-debugger-setup-overlay-arrow)
      (jade-debugger-highlight-node frame))))

(defun jade-debugger-setup-overlay-arrow ()
  (let ((pos (line-beginning-position)))
    (setq overlay-arrow-string "=>")
    (setq overlay-arrow-position (make-marker))
    (set-marker overlay-arrow-position pos (current-buffer))))

(defun jade-debugger-highlight-node (frame)
  (let ((beg (point))
        (end (line-end-position)))
    (remove-overlays)
    (overlay-put (make-overlay beg end)
                 'face 'jade-highlight-face)))

(defun jade-debugger-top-frame ()
  "Return the top frame of the current debugging context."
  (car jade-debugger-frames))

(defun jade-debugger-step-into ()
  (interactive)
  (jade-backend-step-into jade-backend))

(defun jade-debugger-step-over ()
  (interactive)
  (jade-backend-step-over jade-backend))

(defun jade-debugger-step-out ()
  (interactive)
  (jade-backend-step-out jade-backend))

(defun jade-debugger-resume ()
  (interactive)
  (jade-backend-resume jade-backend #'jade-debugger-resumed)
  (let ((locals-buffer (jade-debugger-locals-get-buffer)))
    (when locals-buffer
      (kill-buffer locals-buffer))
    (kill-buffer (jade-debugger-get-buffer))))

(defun jade-debugger-here ()
  (interactive)
  (jade-backend-continue-to-location jade-backend
                                     `((scriptId . ,(map-nested-elt (jade-debugger-top-frame)
                                                                    '(location scriptId)))
                                       (lineNumber . ,(1- (count-lines (point-min) (point)))))))

(defun jade-debugger-evaluate (arg expression)
  "Prompt for EXPRESSION to be evaluated.
Evaluation happens in the context of the current call frame.

With a prefix argument ARG, inspect the result of the
evaluation."
  (interactive "P\nsEvaluate on frame: ")
  (jade-backend-evaluate-on-frame jade-backend
                                  expression
                                  (jade-debugger-top-frame)
                                  (lambda (value error)
                                    (if arg
                                        (jade-inspector-inspect value)
                                      (message (jade-description-string value))))))

(defun jade-debugger-evaluate-last-node (arg)
  "Evaluate the node before point.

This is similar to `evaluate-last-sexp', but for JavaScript buffers.
With a prefix argument, ARG, inspect the result of the evaluation."
  (interactive "P")
  (jade-debugger-evaluate arg (js2-node-string (jade-debugger-node-before-point))))

(defun jade-debugger-node-before-point ()
  "Return the node before point to be evaluated."
  (save-excursion
    (forward-comment -1)
    (while (looking-back ":;,")
      (backward-char 1))
    (backward-char 1)
    (let* ((node (js2-node-at-point))
           (parent (js2-node-parent node)))
      ;; Heuristics for finding the node to evaluate: if the parent of the node
      ;; before point is a prop-get node (i.e. foo.bar) and if it starts before
      ;; the current node, meaning that the point is on the node following the
      ;; parent, then evaluate the content of the parent node:
      ;;
      ;; (underscore represents the point)
      ;; foo.ba_r // => evaluate foo.bar
      ;; foo_.bar // => evaluate foo
      ;; foo.bar.baz_() // => evaluate foo.bar.baz
      ;; foo.bar.baz()_ // => evaluate foo.bar.baz()
      (while (and (js2-prop-get-node-p parent)
                  (< (js2-node-abs-pos parent)
                     (js2-node-abs-pos node)))
        (setq node parent))
      node)))

(defun jade-debugger-get-buffer-create (frames backend connection)
  "Create a debugger buffer unless one exists, and return it."
  (let ((buf (jade-debugger-get-buffer)))
    (unless buf
      (setq buf (get-buffer-create (jade-debugger-buffer-name)))
      (jade-debugger-setup-buffer buf backend connection))
    (with-current-buffer buf
      (setq-local jade-debugger-frames frames))
    buf))

(defun jade-debugger-buffer-name ()
    (concat "*JS Debugger " (map-elt jade-connection 'url) "*"))

(defun jade-debugger-get-buffer ()
  (get-buffer (jade-debugger-buffer-name)))

(defun jade-debugger-setup-buffer (buffer backend connection)
  (with-current-buffer buffer
    (funcall jade-debugger-major-mode)
    (setq-local jade-connection connection)
    (setq-local jade-backend backend)
    (jade-debugger-mode)
    (read-only-mode)))

(defvar jade-debugger-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map " " #'jade-debugger-step-over)
    (define-key map (kbd "i") #'jade-debugger-step-into)
    (define-key map (kbd "o") #'jade-debugger-step-out)
    (define-key map (kbd "c") #'jade-debugger-resume)
    (define-key map (kbd "l") #'jade-debugger-locals)
    (define-key map (kbd "q") #'jade-debugger-resume)
    (define-key map (kbd "h") #'jade-debugger-here)
    (define-key map (kbd "e") #'jade-debugger-evaluate)
    (define-key map (kbd "C-x C-e") #'jade-debugger-evaluate-last-node)
    map))

(define-minor-mode jade-debugger-mode
  "Minor mode for debugging JS scripts.

\\{jade-debugger-mode-map}"
  :group 'jade
  :lighter " JS debug"
  :keymap jade-debugger-mode-map)

;;; Locals

(declare 'jade-backend-get-properties)

(defun jade-debugger-locals (&optional no-pop)
  "Inspect the local variables in the current stack frame's scope.
Unless NO-POP is non-nil, pop the locals buffer."
  (interactive)
  (let* ((buf (jade-debugger-locals-get-buffer-create))
        (inhibit-read-only t))
    (with-current-buffer buf
      (erase-buffer)))
  (seq-do (lambda (scope)
            (jade-backend-get-properties
             jade-backend
             (map-nested-elt scope '(object objectid))
             (lambda (properties)
               (jade-debugger-locals-render-properties properties scope no-pop))))
          ;; do not inspect the window object
          (seq-remove (lambda (scope)
                        (string= (map-elt scope 'type) "global"))
                      (map-elt (jade-debugger-top-frame) 'scope-chain))))

(defun jade-debugger-locals-maybe-refresh ()
  "When a local inspector is open, refresh it."
  (interactive)
  (let ((buf (jade-debugger-locals-get-buffer)))
    (when buf
      (jade-debugger-locals t))))

(defun jade-debugger-locals-render-properties (properties scope &optional no-pop)
  (let* ((buf (jade-debugger-locals-get-buffer-create))
         (inhibit-read-only t)
         (name (map-elt scope 'name))
         (type (map-elt scope 'type))
         (description (if (or (null name)
                              (string= name "undefined"))
                          type
                        name)))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-max))
        (jade-render-keyword description)
        (insert "\n\n")
        (jade-render-properties properties scope)
        (insert "\n")))
    (unless no-pop
      (pop-to-buffer buf))))

(defun jade-debugger-locals-get-buffer ()
  (get-buffer (jade-debugger-locals-buffer-name)))

(defun jade-debugger-locals-buffer-name ()
  (concat "*JS Debugger Locals " (map-elt jade-connection 'url) "*"))

(defun jade-debugger-locals-get-buffer-create ()
  "Create a locals buffer unless one exists, and return it."
  (let ((buf (jade-debugger-locals-get-buffer)))
    (unless buf
      (setq buf (generate-new-buffer (jade-debugger-locals-buffer-name)))
      (jade-debugger-locals-setup-buffer buf jade-backend jade-connection))
    buf))

(defun jade-debugger-locals-setup-buffer (buffer backend connection)
  (with-current-buffer buffer
    (jade-debugger-locals-mode)
    (read-only-mode)
    (setq-local jade-connection connection)
    (setq-local jade-backend backend)))

(defvar jade-debugger-locals-mode-map
  (let ((map (copy-keymap jade-inspector-mode-map)))
    (define-key map "g" nil)
    (define-key map "l" nil)
    map))

(define-derived-mode jade-debugger-locals-mode jade-inspector-mode "Locals"
  "Major mode for inspecting local variables in a scope-chain.

\\{jade-debugger-locals-mode-map}")

(provide 'jade-debugger)
;;; jade-debugger.el ends here
