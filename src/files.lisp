;;;; src/files.lisp -- loading files into a listener, and saving its transcript.
;;;;
;;;; File > Open... and a file dropped on the window both end here, and both
;;;; LOAD by typing `(load "/path/to/file.lisp")' at the prompt, as a person
;;;; would: the transcript records what was loaded, its output and its errors
;;;; land where everything else does, an error in the file opens the debugger,
;;;; and the line goes into the history to be run again.  Nothing is loaded on
;;;; thread 1, which must never evaluate.
;;;;
;;;; The front end supplies the panels and the drop; this file is what they do,
;;;; and so what `make test' covers.

(in-package #:lisp-listener)

(defparameter *loadable-file-types* '("lisp" "lsp" "cl" "l" "asd" "fasl")
  "The file types a drop or Open... loads.  Anything else dropped on the window
is left to the text view, which inserts its path.")

(defun loadable-file-p (path)
  (let ((type (pathname-type (pathname path))))
    (and type (member type *loadable-file-types* :test #'string-equal) t)))

(defun load-form (path)
  "The line typed at the prompt to load PATH: `(load \"/path/to/file.lisp\")'."
  (with-standard-io-syntax
    (let ((*print-readably* nil))
      (format nil "(load ~s)" (namestring path)))))

(defun load-files-into-listener (listener paths)
  "Load each of PATHS that is a Lisp file, in order, at LISTENER's prompt.
Thread 1.  Answers how many it typed.

Each is its own line, so an error in one opens the debugger with the others
still queued behind it -- and taking the top-level restart there goes on to
the next, which is what typing them one after another would do too."
  (let ((count 0))
    (dolist (path paths count)
      (when (loadable-file-p path)
        (type-into-listener listener (load-form path) :record t)
        (incf count)))))

;;; A file the system hands over ---------------------------------------------------
;;;
;;; On a phone a file arrives from another app -- Files, Mail, a share sheet --
;;; as a URL the app may read only while it is being handed over, and LOAD
;;; happens later, on the listener thread.  So the file is copied somewhere the
;;; app can always read, and the copy is what is loaded.

(defun settled-namestring (path)
  "PATH as a string, without the /private that iOS puts in front of /var in
some of its answers and not in others."
  (let ((name (namestring path)))
    (if (eql 0 (search "/private/var/" name))
        (subseq name (length "/private"))
        name)))

(defun copy-file-bytes (from to)
  "Copy the file FROM to TO, replacing it.  Answers TO."
  (ensure-directories-exist to)
  (with-open-file (in from :element-type '(unsigned-byte 8))
    (with-open-file (out to :element-type '(unsigned-byte 8)
                            :direction :output :if-exists :supersede)
      (let ((buffer (make-array 8192 :element-type '(unsigned-byte 8))))
        (loop for count = (read-sequence buffer in)
              while (plusp count)
              do (write-sequence buffer out :end count)))))
  to)

(defun import-opened-file (path directory)
  "The file to LOAD for PATH, which the system has just handed the app:
PATH itself when it is already under DIRECTORY -- the app's own documents,
which it can read at any time -- and otherwise a copy of it in Opened/ there.

Called while the file can still be read, which for a file from another app is
only until the caller returns; a second file of the same name replaces the
first, as opening it again should."
  (let ((name (settled-namestring path))
        (home (settled-namestring directory)))
    (if (eql 0 (search home name))
        name
        (namestring
         (copy-file-bytes name (merge-pathnames
                                (concatenate 'string "Opened/" (file-namestring name))
                                directory))))))

(defun transcript-text-of (listener)
  "Everything in LISTENER's transcript, as a string.  Thread 1."
  (let ((pointer (listener-view listener)))
    (transcript-substring pointer 0 (transcript-length pointer))))

(defun save-transcript (listener path)
  "Write LISTENER's transcript to PATH, as plain UTF-8 text.  Thread 1.
Answers PATH.  The colours are the window's; the words are the record."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :utf-8)
    (write-string (transcript-text-of listener) out))
  path)

;;; (download url) ----------------------------------------------------------------
;;;
;;; A file from the network, by Foundation, which both platforms have and which
;;; the image can already reach: there is no HTTP library in the iOS image, and
;;; the Mac's would be one more thing to load.  -dataWithContentsOfURL: blocks,
;;; which is right here -- this runs on the listener thread, never thread 1 --
;;; and an interrupt waits for it, as it does for any foreign call.

(defun url-file-name (nsurl)
  "The last part of NSURL's path, to name the file after: \"x.lisp\" for
https://host/a/x.lisp?y=1, or NIL when the path has none."
  (let ((name (ignore-errors
               (objc:ns-string-to-string (objc:invoke nsurl "lastPathComponent")))))
    (and name (plusp (length name)) (string/= name "/") name)))

(defun lisp-listener:download (url &optional name)
  "Fetch URL and keep it as a file; answer where it went.

NAME is what to call it, the last part of the URL's path if not given.  A name
with no directory goes in your own folder: ~/Downloads on the Mac, the app's
folder in Files on a phone.  Only https:// addresses are fetched -- the system
refuses plain http://.  A file:// URL copies a file.

    (download \"https://example.com/lib/thing.lisp\")
    (load *)"
  (let ((nsurl (objc:invoke "NSURL" "URLWithString:" url)))
    (unless (live-pointer-p nsurl)
      (error "~s is not a URL." url))
    (let* ((path (merge-pathnames (or name (url-file-name nsurl) "download")
                                  (or (ignore-errors (download-directory))
                                      *default-pathname-defaults*)))
           (data (objc:invoke "NSData" "dataWithContentsOfURL:" nsurl)))
      (unless (live-pointer-p data)
        (error "Nothing came back from ~a.~:[~;  Only https:// addresses are fetched.~]"
               url (eql 0 (search "http:" url :test #'char-equal))))
      (ensure-directories-exist path)
      (unless (objc:invoke-bool data "writeToFile:atomically:" (namestring path) t)
        (error "~a could not be written." (namestring path)))
      (truename path))))
