;;; weechat-relay --- Implementation of Weechat's relay protocol ;; -*- lexical-binding: t -*-

;; Copyright (C) 2013 Moritz Ulrich

;; Author: Moritz Ulrich (moritz@tarn-vedra.de)
;; Keywords: irc chat network weechat

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

(require 'cl-lib)
(require 'bindat)
(require 's)
(require 'pp)

(defvar weechat-relay-buffer-name "*weechat-relay*"
  "Buffer holding the connection to the host weechat instance.")

(defvar weechat-relay-log-buffer-name "*weechat-relay-log*"
  "Buffer name to use as debug log.
Set to nil to disable logging.")

(defvar weechat-relay-log-level :info
  "Minimum log level.
Might be one of :debug, :info, :warn, :error or nil")

(defvar weechat-relay-message-function nil
  "Function to call when receiving a new weechat message.")

(defvar weechat-relay-ignored-message-ids '("_nicklist")
  "IDs to ignore.")

(defvar weechat-relay-disconnect-hook ()
  "Hook run when the relay disconnects.")

(defvar weechat-relay-connect-hook ()
  "Hook run when the relay connects.
Note: This DOESN'T mean the client can is already authenticated
to the relay server.")

;;; Code:

(defvar weechat--relay-id-callback-hash (make-hash-table :test 'equal)
  "Alist mapping from ids to functions.
Incoming message-ids will be searched in this alist and the
corresponding function will be called.")

(defun weechat-relay-log (text &optional level)
  "Log `TEXT' to `weechat-relay-log-buffer-name' if enabled.
`LEVEL' might be one of :debug :info :warn :error.  Defaults
to :info"
  (let ((log-level-alist '((:debug . 0)
                           (:info  . 1)
                           (:warn  . 2)
                           (:error . 3))))
    (when (and (>= (assoc-default (or level :info) log-level-alist)
                   (assoc-default weechat-relay-log-level log-level-alist))
               weechat-relay-log-level
               weechat-relay-log-buffer-name)
      (with-current-buffer (get-buffer-create weechat-relay-log-buffer-name)
        (let ((old-point (point)))
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-max))
              (insert (s-trim text))
              (newline)))
          (goto-char old-point))))))

(defun weechat--relay-send-message (text &optional id)
  "Send message TEXT with optional ID.
Trim TEXT prior to sending it."
  (let ((msg (concat (when id (format "(%s) " id)) (s-trim text) "\n")))
    (weechat-relay-log (format "Sending msg: '%s'" (s-trim msg))
                       :debug)
    (send-string (get-buffer-process weechat-relay-buffer-name)
                 msg)))

(defun weechat-relay-authenticate (password)
  "Authenticate to weechat with PASSWORD."
  (weechat--relay-send-message (format "init password=%s,compression=off\n" password)))

(defun weechat--relay-bindat-unsigned-to-signed (num bytes)
  "Convert an unsigned int NUM to signed int.
NUM is in two-complement representation with BYTES bytes.
Useful because bindat does not support signed numbers."
  (if (> num (- (expt 2 (- (* 8 bytes) 1)) 1))
      (- num (expt 2 (* 8 bytes)))
    num))

(defun weechat--relay-unpack-int (data)
  "Unpack a four-byte signed integer from unibyte string DATA.
Return the value and number of bytes consumed."
  (cl-values
   (weechat--relay-bindat-unsigned-to-signed
    (bindat-get-field
     (bindat-unpack '((val u32)) data)
     'val)
    4)
   4))

(defconst weechat--relay-lon-spec
  '((len u8)
    (val str (eval (weechat--relay-bindat-unsigned-to-signed
                    (bindat-get-field struct 'len)
                    1)))))

(defun weechat--relay-unpack-lon (data)
  (let ((obj (bindat-unpack weechat--relay-lon-spec data)))
    (cl-values (string-to-number (decode-coding-string (bindat-get-field obj 'val) 'utf-8))
            (bindat-length weechat--relay-lon-spec obj))))

(defun weechat--relay-unpack-chr (data)
  "Unpack a one byte char from unibyte string DATA.
Returns value and bytes consumed."
  (cl-values
   (bindat-get-field
    (bindat-unpack '((val u8)) data)
    'val)
   1))

(defconst weechat--relay-str-spec
  '((len u32)
    (val str (eval (let ((len (weechat--relay-bindat-unsigned-to-signed
                               (bindat-get-field struct 'len)
                               4)))
                     ;; Hack for signed/unsigned problems
                     (if (<= len 0) 0 len))))))

(defun weechat--relay-unpack-str (data)
  "Unpacks a weechat-relay-string from unibyte string DATA.
Optional second return value contains length of parsed data."
  (let ((obj (bindat-unpack weechat--relay-str-spec data)))
    (cl-values (decode-coding-string (bindat-get-field obj 'val) 'utf-8)
            (bindat-length weechat--relay-str-spec obj))))

(defconst weechat--relay-buf-spec
  '((len u32)
    (val vec (eval (let ((len (weechat--relay-bindat-unsigned-to-signed
                               (bindat-get-field struct 'len)
                               4)))
                     ;; Hack for signed/unsigned problems
                     (if (<= len 0) 0 len))))))

(defun weechat--relay-unpack-buf (data)
  (let ((obj (bindat-unpack weechat--relay-buf-spec data)))
    (cl-values (bindat-get-field obj 'val)
            (bindat-length weechat--relay-buf-spec obj))))

(defconst weechat--relay-ptr-spec
  '((len u8)
    (val str (eval (let ((len (weechat--relay-bindat-unsigned-to-signed
                               (bindat-get-field struct 'len)
                               1)))
                     ;; Hack for signed/unsigned problems
                     (if (<= len 0) 0 len))))))

(defun weechat--relay-unpack-ptr (data)
  "Unpack a string encoded in weechat's binary representation.
DATA must be an unibyte string.  Return string-value and number
of bytes consumed."
  (let ((obj (bindat-unpack weechat--relay-ptr-spec data)))
    (cl-values (concat "0x" (bindat-get-field obj 'val))
            (bindat-length weechat--relay-ptr-spec obj))))

(defconst weechat--relay-tim-spec
  '((len u8)
    (val str (eval (let ((len (weechat--relay-bindat-unsigned-to-signed
                               (bindat-get-field struct 'len)
                               1)))
                     ;; Hack for signed/unsigned problems
                     (if (<= len 0) 0 len))))))

(defun weechat--relay-unpack-tim (data)
  (let ((obj (bindat-unpack weechat--relay-tim-spec data)))
    (cl-values (let ((val (string-to-number
                           (bindat-get-field obj 'val))))
                 (unless (zerop val)
                   (seconds-to-time val)))
               (bindat-length weechat--relay-tim-spec obj))))

(defconst weechat--relay-htb-spec
  '((key-type str 3)
    (val-type str 3)
    (count u32)))

(defun weechat--relay-unpack-htb (data)
  (let* ((obj (bindat-unpack weechat--relay-htb-spec data))
         (count (weechat--relay-bindat-unsigned-to-signed
                 (bindat-get-field obj 'count)
                 4))
         (key-type (bindat-get-field obj 'key-type))
         (val-type (bindat-get-field obj 'val-type))
         (key-fn (symbol-function (intern (concat "weechat--relay-unpack-" key-type))))
         (val-fn (symbol-function (intern (concat "weechat--relay-unpack-" val-type))))
         (offset (bindat-length weechat--relay-htb-spec obj))
         (acc ()))
    (dotimes (_ count)
      (cl-multiple-value-bind (key key-len) (funcall key-fn (substring data offset))
        (cl-multiple-value-bind (val val-len) (funcall val-fn (substring data (+ offset key-len)))
          (setq acc (cons (cons key val) acc))
          (setq offset (+ offset key-len val-len)))))
    (cl-values acc
            offset)))

(defconst weechat--relay-arr-spec
  '((type str 3)
    (count u32)))

(defun weechat--relay-unpack-arr (data)
  (let* ((obj (bindat-unpack weechat--relay-arr-spec data))
         (count (weechat--relay-bindat-unsigned-to-signed
                 (bindat-get-field obj 'count)
                 4))
         (type (bindat-get-field obj 'type))
         (unpack-fn (symbol-function (intern (concat "weechat--relay-unpack-" type))))
         (offset (bindat-length weechat--relay-arr-spec obj))
         (acc ()))
    (dotimes (_ count)
      (cl-multiple-value-bind (val val-len) (funcall unpack-fn (substring data offset))
        (setq acc (append acc (list val)))
        (setq offset (+ offset val-len))))
    (cl-values acc offset)))

(defalias 'weechat--relay-parse-chr 'weechat--relay-unpack-chr)
(defalias 'weechat--relay-parse-int 'weechat--relay-unpack-int)
(defalias 'weechat--relay-parse-lon 'weechat--relay-unpack-lon)
(defalias 'weechat--relay-parse-str 'weechat--relay-unpack-str)
(defalias 'weechat--relay-parse-buf 'weechat--relay-unpack-buf)
(defalias 'weechat--relay-parse-ptr 'weechat--relay-unpack-ptr)
(defalias 'weechat--relay-parse-tim 'weechat--relay-unpack-tim)
(defalias 'weechat--relay-parse-arr 'weechat--relay-unpack-arr)

(defun weechat--relay-parse-inf (data)
  (cl-multiple-value-bind (name len) (weechat--relay-unpack-str data)
    (cl-multiple-value-bind (value len*) (weechat--relay-unpack-str (substring data len))
      (cl-values (cons name value)
              (+ len len*)))))

(defconst weechat--relay-inl-item-spec
  '((name struct weechat--relay-str-spec)
    (type str 3)))

(defun weechat--relay-parse-inl-item (data)
  (let* ((count (weechat--relay-bindat-unsigned-to-signed
                 (bindat-get-field
                  (bindat-unpack '((len u32)) data) 'len)
                 4))
         (offset 4)
         (acc ()))
    (while (< (length acc) count)
      (let* ((obj (bindat-unpack weechat--relay-inl-item-spec
                                 (substring data offset)))
             (fun (symbol-function (intern (concat "weechat--relay-unpack-"
                                                   (bindat-get-field obj 'type))))))
        (setq offset (+ offset (bindat-length weechat--relay-inl-item-spec obj)))
        (cl-multiple-value-bind (value offset*) (funcall fun (substring data offset))
          (setq offset (+ offset offset*))
          (setq acc (cons
                     (cons (bindat-get-field obj 'name 'val) value)
                     acc)))))
    (cl-values acc
            offset)))

(defconst weechat--relay-inl-spec
  '((name struct weechat--relay-str-spec)
    (count u32)))

(defun weechat--relay-parse-inl (data)
  (let* ((obj (bindat-unpack weechat--relay-inl-spec data))
         (acc ())
         (count (weechat--relay-bindat-unsigned-to-signed
                 (bindat-get-field obj 'count)
                 4))
         (offset (bindat-length weechat--relay-inl-spec obj)))
    (dotimes (_ count)
      (cl-multiple-value-bind (item offset*) (weechat--relay-parse-inl-item (substring data offset))
        (setq acc (cons item acc))
        (setq offset (+ offset offset*))))
    (cl-values acc
            offset)))

(defun weechat--relay-parse-hda-item (h-path-length name-type-alist data)
  (let ((p-path ())
        (offset 0)
        (result ()))
    (dotimes (_ h-path-length)
      (cl-multiple-value-bind (el offset*) (weechat--relay-unpack-ptr (substring data offset))
        (setq p-path (cons el p-path))
        (setq offset (+ offset offset*))))
    (dolist (name-type name-type-alist)
      (let ((fun (symbol-function (intern (concat "weechat--relay-unpack-" (cdr name-type))))))
        (cl-multiple-value-bind (obj offset*) (funcall fun (substring data offset))
          (setq result (cons (cons (car name-type) obj) result))
          (setq offset (+ offset offset*)))))
    (cl-values (cons (reverse p-path) result)
            offset)))

(defconst weechat--relay-hdh-spec
  '((h-path struct weechat--relay-str-spec)
    (keys struct weechat--relay-str-spec)
    (count u32)))

;;; from http://lists.gnu.org/archive/html/help-gnu-emacs/2009-06/msg00764.html
(defun weechat--partition-list (list length)
  (cl-loop while list
           collect (cl-subseq list 0 length)
           do (setf list (nthcdr length list))))

(defun weechat--hda-split-keys-string (str)
  (mapcar (lambda (x)
            (cons (car x)
                  (cadr x)))
          (weechat--partition-list (split-string str "[:,]") 2)))

(defun weechat--relay-parse-hda (data)
  (let* ((obj (bindat-unpack weechat--relay-hdh-spec data))
         (count (weechat--relay-bindat-unsigned-to-signed
                 (bindat-get-field obj 'count)
                 4))
         (name-type-alist (weechat--hda-split-keys-string
                           (bindat-get-field obj 'keys 'val)))
         (h-path-length (length (split-string (bindat-get-field obj 'h-path 'val) "[/]")))
         (offset (+ (bindat-length weechat--relay-hdh-spec obj)))
         (acc ()))
    (dotimes (_ count)
      (cl-multiple-value-bind (obj offset*) (weechat--relay-parse-hda-item
                                             h-path-length name-type-alist (substring data offset))
        (setq acc (cons obj acc))
        (setq offset (+ offset offset*))))
    (let ((h-path (bindat-get-field obj 'h-path 'val)))
      (cl-values (list h-path acc)
              offset))))

(defconst weechat--relay-message-spec
  '((length u32)
    (compression u8)
    (id struct weechat--relay-str-spec)
    (data vec (eval (let ((l (- (bindat-get-field struct 'length)
                                4   ;length
                                1   ;compression
                                (+ 4 (length (bindat-get-field struct 'id 'val))))))
                      l)))))

(defun weechat--unpack-message-contents (data)
  (let* ((type (substring data 0 3))
         (fun (symbol-function (intern (concat "weechat--relay-parse-" type)))))
    (cl-multiple-value-bind (obj len) (funcall fun (string-make-unibyte (substring data 3)))
      (cl-values obj
              (+ len 3)))))

(defun weechat-unpack-message (message-data)
  "Unpack weechat relay message in MESSAGE-DATA.
Return a list: (id data)."
  (let* ((msg (bindat-unpack weechat--relay-message-spec message-data))
         (data (concat (bindat-get-field msg 'data)))
         (msg-id (bindat-get-field msg 'id 'val))
         (ignore-msg (member msg-id weechat-relay-ignored-message-ids))
         (offset 0)
         (acc ()))
    ;; Only no-compression is supported atm
    (unless (= 0 (bindat-get-field msg 'compression))
      (error "Compression not supported"))
    (unless ignore-msg
      (while (< offset (length data))
        (cl-multiple-value-bind (obj offset*) (weechat--unpack-message-contents
                                               (substring data offset))
          (setq offset (+ offset offset*))
          (setq acc (cons obj acc)))))
    (cl-values (cons msg-id (if ignore-msg '(ignored) (reverse acc)))
            (bindat-get-field msg 'length))))

(defun weechat--message-available-p (&optional buffer)
  "Check if a weechat relay message available in BUFFER.
BUFFER defaults to the current buffer."
  (with-current-buffer (get-buffer (or buffer
                                       weechat-relay-buffer-name))
    (and (> (buffer-size) 5)
         (>= (buffer-size)
             (bindat-get-field
              (bindat-unpack '((len u32))
                             (buffer-string))
              'len)))))

(defun weechat--relay-parse-new-message (&optional buffer)
  (with-current-buffer (get-buffer (or buffer
                                       weechat-relay-buffer-name))
    (when (weechat--message-available-p (current-buffer))
      (cl-multiple-value-bind (ret len) (weechat-unpack-message
                                         (buffer-string))
        (weechat-relay-log (format "Consumed %d bytes" len) :debug)
        (let ((inhibit-read-only t))
          (delete-region (point-min) (+ (point-min) len)))
        ret))))



(defun weechat-relay-get-id-callback (id)
  (gethash id weechat--relay-id-callback-hash))

(defun weechat-relay-remove-id-callback (id)
  (let ((fun (weechat-relay-get-id-callback id)))
    (remhash id weechat--relay-id-callback-hash)
    fun))

(defun weechat-relay-add-id-callback (id function &optional one-shot force)
  (unless id
    (error "ID must not be nil"))
  (when (weechat-relay-get-id-callback id)
    (unless force
      (error "ID '%s' is already in `weechat--relay-id-callback-hash'" id))
    (weechat-relay-remove-id-callback id))
  (let ((function* (if one-shot
                       (lambda (x)
                         (funcall function x)
                         (weechat-relay-remove-id-callback id))
                     function)))
    (puthash id function* weechat--relay-id-callback-hash)))

(defun weechat-relay-send-command (command &optional callback)
  "Send COMMAND to relay and call CALLBACK with reply.
CALLBACK takes one argument (the response data) which is a list."
  (let ((id (symbol-name (cl-gensym))))
    (when (functionp callback)
      (weechat-relay-add-id-callback id callback 'one-shot))
    (weechat--relay-send-message command id)))

(defun weechat--relay-process-filter (proc string)
  (with-current-buffer (process-buffer proc)
    (weechat-relay-log (format "Received %d bytes" (length string)) :debug)
    ;; Insert the text, advancing the process marker.
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert (string-make-unibyte string)))
    (while (weechat--message-available-p)
      (let* ((data (weechat--relay-parse-new-message))
             (id (weechat--message-id data)))
        ;; If buffer is available, log message
        (weechat-relay-log (pp-to-string data) :debug)
        ;; Call `weechat-relay-message-function'
        (when (functionp weechat-relay-message-function)
          (funcall weechat-relay-message-function data))
        ;; Call callback from `weechat--relay-id-callback-hash'
        (if (functionp (weechat-relay-get-id-callback id))
            (funcall (weechat-relay-get-id-callback id)
                     (weechat--message-data data)))))))

(defvar weechat--relay-connected-callback)

(defun weechat--relay-process-sentinel (proc _)
  (let ((event (process-status proc)))
    (weechat-relay-log (format "Received event: %s\n" event))
    (cl-case event
      ('closed (run-hooks 'weechat-relay-disconnect-hook))
      ('open (progn
               (when (functionp weechat--relay-connected-callback)
                 (funcall weechat--relay-connected-callback)
                 (setq weechat--relay-connected-callback nil))
               (run-hooks 'weechat-relay-connect-hook)))
      ('failed (progn (error "Failed to connect to weechat relay")
                      (weechat-relay-disconnect))))))

(defun weechat-relay-connect (host port &optional callback)
  "Open a new weechat relay connection to HOST at PORT."
  (setq weechat--relay-connected-callback callback)
  (make-network-process :name "weechat-relay"
                        :buffer weechat-relay-buffer-name
                        :host host
                        :service port
                        :filter #'weechat--relay-process-filter
                        :sentinel #'weechat--relay-process-sentinel
                        :nowait t
                        :filter-multibyte nil
                        :coding 'binary)
  (with-current-buffer (get-buffer-create
                        weechat-relay-log-buffer-name)
    (buffer-disable-undo))
  (with-current-buffer (get-buffer weechat-relay-buffer-name)
    (setq buffer-read-only t)
    (set-buffer-multibyte nil)
    (buffer-disable-undo)))

(defun weechat-relay-connected-p ()
  (and (get-buffer weechat-relay-buffer-name)
       (get-buffer-process weechat-relay-buffer-name)
       (process-live-p (get-buffer-process weechat-relay-buffer-name))
       t))

(defun weechat-relay-disconnect ()
  "Disconnect current weechat relay connection and close all buffers."
  (when (weechat-relay-connected-p)
    (weechat--relay-send-message "quit")
    (with-current-buffer weechat-relay-buffer-name
      (delete-process
       (get-buffer-process (current-buffer)))
      (kill-buffer))
    (when (get-buffer weechat-relay-log-buffer-name)
      (kill-buffer weechat-relay-log-buffer-name))))

(defun weechat--message-id (message)
  (car message))

(defun weechat--message-data (message)
  "Return a list with data in MESSAGE."
  (cdr message))

(defun weechat--hdata-path (hdata)
  (car hdata))

(defun weechat--hdata-values (hdata)
  (cadr hdata))

(defun weechat--hdata-value-pointer-path (value)
  (car value))

(defun weechat--hdata-value-alist (value)
  (cdr value))

(provide 'weechat-relay)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; weechat-relay.el ends here
