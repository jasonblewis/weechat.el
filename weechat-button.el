;;; weechat-button --- Add buttons to text ;; -*- lexical-binding: t -*-

;; Copyright (C) 2013 Rüdiger Sonderfeld <ruediger@c-plusplus.de>

;; Author: Rüdiger Sonderfeld <ruediger@c-plusplus.de>
;; Keywords: irc chat network weechat
;; URL: https://github.com/the-kenny/weechat.el

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
;; This code is heavily inspired by erc-button.el!

;;; Code:
;;

(require 'weechat)
(require 'button)

;;; Customize

(defgroup weechat-button nil
  "WeeChat button interface (URLification)."
  :link '(url-link "https://github.com/the-kenny/weechat.el")
  :prefix "weechat-button"
  :group 'weechat)

(defcustom weechat-button-url-regexp
  (concat "\\(www\\.\\|\\(s?https?\\|"
          "ftp\\|file\\|gopher\\|news\\|telnet\\|wais\\|mailto\\):\\)"
          "\\(//[-a-zA-Z0-9_.]+:[0-9]*\\)?"
          "[-a-zA-Z0-9_=!?#$@~`%&*+\\/:;.,()]+[-a-zA-Z0-9_=#$@~`%&*+\\/()]")
  "Regexp to match URLs.
Copied from erc-button.el."
  :type 'regexp
  :group 'weechat-button)

(defcustom weechat-button-default-log-buffer "*WeeChat URL Log*"
  "Buffer name for URL log.

Valid values include a string describing a buffer name or nil to
disable url logging (except when an explicit buffer name is
defined in `weechat-button-list')"
  :group 'weechat-button
  :type 'boolean)

(defcustom weechat-button-buttonize-url t
  "Buttonize url links?"
  :group 'weechat-button
  :type 'boolean)

(defcustom weechat-button-buttonize-channels t
  "Buttonize channel links?"
  :group 'weechat-button
  :type 'boolean)

(defcustom weechat-button-buttonize-symbols t
  "Buttonize symbol links?"
  :group 'weechat-button
  :type 'boolean)

(defcustom weechat-button-buttonize-emails nil
  "Buttonize e-mail link?"
  :group 'weechat-button
  :type 'boolean)

(defcustom weechat-button-buttonize-info nil
  "Buttonize info links?
Format is (info \"link\")."
  :group 'weechat-button
  :type 'boolean)

(defcustom weechat-button-buttonize-nicks t
  "Buttonize nicknames?"
  :group 'weechat-button
  :type 'boolean)

(defcustom weechat-button-list
  '((weechat-button-url-regexp 0 weechat-button-buttonize-url t "Browse URL"
                               browse-url 0)
    ("#[-#+_[:alnum:]]+" 0 weechat-button-buttonize-channels nil "Join Channel"
     weechat-join 0)
    ("\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]\\{2,4\\}\\b" 0 weechat-button-buttonize-emails nil "email" weechat-button--mailto 0)
    ("[`]\\([-_.[:alnum:]]+\\)[']" 1 weechat-button-buttonize-symbols nil "Describe Symbol"
     weechat-button--describe-symbol 1)
    ("(info \"\\(([[:alnum:]]+) .+?\\)\"" 1 weechat-button-buttonize-info nil "info"
     info 1))
  "List of potential buttons in WeeChat chat buffers.
Each entry has the form (REGEXP BUTTON-MATCH BUTTONIZE? LOG HELP-ECHO ACTION
DATA-MATCH...), where

REGEXP is a string or variable containing a regular expression to match buttons.

BUTTON-MATCH is the number of the regexp grouping which represents the actual
  button.

BUTTONIZE? is `eval'd and the button is only created if the return value is
  non-nil.

LOG decides if `weechat-button-log-functions' gets called.

HELP-ECHO is the `help-echo' property of the button.
  See Info node `(elisp) Button Properties'.

ACTION the function to call when the button is selected.

DATA-MATCH... numbers of the regexp groupings whose text will be passed to
  ACTION.

This is similar (but not identical) to `erc-button-alist' in ERC."
  :group 'weechat-button
  :type '(repeat :tag "Buttons"
                 (list (choice :tag "Matches"
                               regexp
                               (variable :tag "Variable containing regexp"))
                       (integer :tag "Number of the regexp section that matches")
                       (choice :tag "When to buttonize"
                               (const :tag "Always" t)
                               (const :tag "Never" t)
                               (sexp :tag "Only when this evaluates to non-nil"))
                       (choice :tag "Log match"
                               (const :tag "To default buffer" t)
                               (const :tag "Never" nil)
                               (string :tag "To buffer name"))
                       (string :tag "Help echo text")
                       (function :tag "Call this function when button is pressed")
                       (repeat :tag "Sections of regexp to send to the function"
                               :inline t
                               (integer :tag "Regexp section number")))))
(put 'weechat-button-list 'risky-local-variable t)

(defvar weechat-button-log-functions nil
  "List of function to run when a button should be logged.

This hook only runs when `LOG' is set to t for the particular
button type.

Functions in list must have two arguments: The button data (the
match string) and a plist describing the button properties.

The functions in this list will be called with
`weechat-narrow-to-line' active.")

;;; Internal functions

(defun weechat-button--handler (button)
  "Handle BUTTON actions.
The function in property `weechat-function' gets called with `weechat-data'."
  (let ((function (button-get button 'weechat-function))
        (data (button-get button 'weechat-data)))
    (when function
      (apply function data))))

(defun weechat-button--log-to-buffer (button-data button-properties)
  (when (and weechat-button-default-log-buffer)
    (let ((weechat-buffer-name (buffer-name)))
      (with-current-buffer (get-buffer-create
                            weechat-button-default-log-buffer) 
        (goto-char (point-max))
        (unless (bolp)
          (insert "\n"))
        (insert weechat-buffer-name "\t")
        (apply #'insert-button button-data button-properties)
        (insert "\n")))))

(add-hook 'weechat-button-log-functions 'weechat-button--log-to-buffer)

(defvar weechat-button-log-buffer-last-log nil)
(defun weechat-button--add-do (entry &optional text-buttons)
  "Handle each button ENTRY.
If TEXT-BUTTONS is non-nil then use `make-text-button instead of `make-button'."
  (save-excursion
    (goto-char (point-min))
    (cl-destructuring-bind
        (regexp-entry button-match buttonize?
                      log help-echo action &rest data-match) entry
      (let* ((regexp (or (and (stringp regexp-entry) regexp-entry)
                         (and (boundp regexp-entry) (symbol-value regexp-entry))))
             (line-date (weechat-line-date))
             (run-hooks?
              (and line-date
                   (or (null weechat-button-log-buffer-last-log)
                       (time-less-p weechat-button-log-buffer-last-log
                                    line-date))))
             (button-fn (if text-buttons
                            #'make-text-button
                          #'make-button)))
        (when regexp
          (while (re-search-forward regexp nil t)
            (let ((start (match-beginning button-match))
                  (end (match-end button-match))
                  (button-data-no-properties
                   (match-string-no-properties button-match))
                  (data (mapcar #'match-string data-match)))
              (when (or (eq buttonize? t)
                        (eval buttonize?))
                (let ((properties (list 'action #'weechat-button--handler
                                        'help-echo help-echo
                                        'follow-link t
                                        'weechat-function action
                                        'weechat-data data)))
                  (when (and log
                             run-hooks?)
                    ;; Hack: Rebind `weechat-button-default-log-buffer'
                    ;; to the value supplied by the button type in
                    ;; `weechat-button-list'
                    (let ((weechat-button-default-log-buffer
                           (if (or (stringp log) (bufferp log))
                               log
                             weechat-button-default-log-buffer)))
                      (run-hook-with-args 'weechat-button-log-functions
                                          button-data-no-properties
                                          properties))
                    (setq weechat-button-log-buffer-last-log line-date))
                  (apply button-fn start end properties))))))))))

(defun weechat-button--add ()
  "Add text buttons to text in buffer."
  (dolist (i weechat-button-list)
    (weechat-button--add-do i))
  (when weechat-button-buttonize-nicks
    (weechat-button--add-nickname-buttons)))

(defvar weechat-user-list) ;; See weechat.el

(defun weechat-button--add-nickname-buttons ()
  "Add nick name buttons."
  (dolist (nick weechat-user-list)
    (unless (s-blank? nick)
      (weechat-button--add-do (list (concat "\\b" (regexp-quote nick) "\\b")
                                    0 t 0 "Nick Action"
                                    #'weechat-button--nick-action
                                    0)
                              'text-button))))

;;; Callback functions

;; This function is copied from `erc-button-describe-symbol'
(defun weechat-button--describe-symbol (symbol-name)
  "Describe SYMBOL-NAME.
Use `describe-function' for functions, `describe-variable' for variables,
and `apropos' for other symbols."
  (let ((symbol (intern-soft symbol-name)))
    (cond ((and symbol (fboundp symbol))
           (describe-function symbol))
          ((and symbol (boundp symbol))
           (describe-variable symbol))
          (t (apropos symbol-name)))))

(defun weechat-button--mailto (email)
  "Call `browse-url' on email with \"mailto:\" prepend."
  (browse-url (concat "mailto:" email)))

(defun weechat-button--send-cmd (cmd &rest options)
  "Send CMD with OPTIONS to WeeChat."
  (weechat-send-input weechat-buffer-ptr
                      (concat cmd " "
                              (when options
                                (cl-reduce (lambda (l r)
                                             (concat l " " r))
                                           options )))))

(defcustom weechat-button-nick-operations
  '(("DeOp" .  (weechat-button--send-cmd "/deop" nick))
    ("Kick" . (weechat-button--send-cmd "/kick" nick
                                        (read-from-minibuffer
                                         (concat "Kick " nick ", reason: "))))
    ("Query" . (weechat-button--send-cmd "/query" nick))
    ("Whois" . (weechat-button--send-cmd "/whois" nick))
    ("Op" . (weechat-button--send-cmd "/op" nick))
    ("Voice" . (weechat-button--send-cmd "/voice" nick)))
  "An alist of possible nickname actions.
The format is (\"Action\" . SEXP) wher SEXP is evaluated with `nick' bound."
  :group 'weechat-button
  :type '(repeat (const (string :tag "Action")
                        sexp)))

(defun weechat-button--nick-action (nick)
  "Ask user for action on NICK and `eval' it."
  (let* ((completion-ignore-case t)
         (action (completing-read (concat "What action to take on '" nick "'? ")
                                  weechat-button-nick-operations))
         (code `(let ((nick ,nick))
                  ,(cdr (assoc-string action weechat-button-nick-operations)))))
    (when code
      (eval code))))

;;; Module load/unload

;;; This is done automatically by `load-library' or `require'.
;;; Unloading is taken care of, because hooks added via `add-hook'
;;; will be removed automatically by `unload-feature'.

;;; If you need special cleanup code, use define a function named
;;; `FEATURE-unload-function'. This function will be called by emacs
;;; right before unloading the feature. Check the docstring of
;;; `unload-feature' for details.

(add-hook 'weechat-insert-modify-hook #'weechat-button--add)

(provide 'weechat-button)

;;; weechat-button.el ends here
