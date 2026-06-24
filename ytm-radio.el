;;; ytm-radio.el --- YouTube Music audio launcher -*- lexical-binding: t; -*-

;; Author: Lucius Chen
;; URL: https://github.com/luciuschen/ytm-radio
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: multimedia
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ytm-radio is a small Emacs audio player for YouTube and YouTube Music
;; URLs.  It relies on yt-dlp for source discovery and mpv for playback.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'json)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-parse)

(defconst ytm-radio--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the loaded ytm-radio package.")

;;; Customization

(defgroup ytm-radio nil
  "Play YouTube and YouTube Music audio from Emacs."
  :group 'multimedia)

(defcustom ytm-radio-yt-dlp-program "yt-dlp"
  "Program name or path used to run yt-dlp."
  :type 'string
  :group 'ytm-radio)

(defcustom ytm-radio-mpv-program "mpv"
  "Program name or path used to run mpv."
  :type 'string
  :group 'ytm-radio)

(defcustom ytm-radio-yt-dlp-extra-args nil
  "Extra arguments passed to yt-dlp when fetching source metadata."
  :type '(repeat string)
  :group 'ytm-radio)

(defcustom ytm-radio-mpv-extra-args nil
  "Extra arguments passed to mpv before the media URL."
  :type '(repeat string)
  :group 'ytm-radio)

(defcustom ytm-radio-ytdl-raw-options nil
  "Raw ytdl options passed to mpv's ytdl hook.
Each string should be in mpv's `--ytdl-raw-options' item form, for
example \"cookies-from-browser=chrome\"."
  :type '(repeat string)
  :group 'ytm-radio)

(defcustom ytm-radio-helper-command
  (expand-file-name "helper/target/debug/ytm-radio-helper" ytm-radio--directory)
  "External helper executable used to fetch account data."
  :type 'file
  :group 'ytm-radio)

(defcustom ytm-radio-helper-auth-file
  (locate-user-emacs-file "ytm-radio/auth.json")
  "Authentication file passed to `ytm-radio-helper-command'.
The file contents are never persisted in ytm-radio state."
  :type 'file
  :group 'ytm-radio)

(defcustom ytm-radio-helper-browser "chrome"
  "Browser specification passed to the helper for cookie import.
The syntax is the same as yt-dlp's BROWSER argument, for example
\"chrome\", \"chrome:Default\", or \"firefox\"."
  :type 'string
  :group 'ytm-radio)

(defcustom ytm-radio-helper-browser-candidates
  '("chrome" "chrome:Default" "firefox" "safari" "brave" "edge"
    "chromium" "opera" "vivaldi" "whale")
  "Browser specifications offered by `ytm-radio-auth-import'."
  :type '(repeat string)
  :group 'ytm-radio)

(defcustom ytm-radio-helper-dia-app
  "/Applications/Dia.app/Contents/MacOS/Dia"
  "Dia executable used by the helper for automatic login import."
  :type 'file
  :group 'ytm-radio)

(defcustom ytm-radio-helper-dia-cdp-port 29317
  "Local DevTools port used for one-shot Dia login import."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (<= 1 value 65535)))))
  :group 'ytm-radio)

(defcustom ytm-radio-helper-use-mock-data nil
  "Whether account import commands should request mock helper data."
  :type 'boolean
  :group 'ytm-radio)

(defcustom ytm-radio-helper-library-limit 100
  "Maximum number of library items requested from the helper."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-helper-home-limit 12
  "Maximum number of items requested for each home recommendation section."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-state-file
  (locate-user-emacs-file "ytm-radio/state.eld")
  "File used to persist ytm-radio sources and last track."
  :type 'file
  :group 'ytm-radio)

(defcustom ytm-radio-display-style 'child-frame
  "Preferred display style for the now-playing view."
  :type '(choice (const :tag "Child frame" child-frame)
                 (const :tag "Regular buffer" buffer))
  :group 'ytm-radio)

(defcustom ytm-radio-child-frame-width 34
  "Fallback width of the now-playing child frame in character columns.
The frame normally fits itself to the displayed cover image."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-child-frame-height 16
  "Fallback height of the now-playing child frame in character rows.
The frame normally fits itself to the displayed cover image."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-cover-cache-directory
  (locate-user-emacs-file "ytm-radio/covers/")
  "Directory used to cache YouTube Music cover images."
  :type 'directory
  :group 'ytm-radio)

(defcustom ytm-radio-cover-max-width 200
  "Displayed now-playing cover image width in pixels."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-cover-max-height 180
  "Maximum displayed cover image height in pixels."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defcustom ytm-radio-browser-thumbnail-size 48
  "Maximum thumbnail size in pixels for items in the browser buffer."
  :type '(restricted-sexp
          :match-alternatives
          ((lambda (value)
             (and (integerp value) (> value 0)))))
  :group 'ytm-radio)

(defconst ytm-radio--cover-left-padding-columns 1
  "Left padding columns used to visually balance cover edge space.")

(defconst ytm-radio--now-playing-thin-padding
  (propertize "\n" 'display '((height 0.25)))
  "Thin vertical padding used inside the now-playing child frame.")

;;; State

(cl-defun ytm-radio--make-track
    (&key id title url duration artist album thumbnail-url source-id source-kind)
  "Return a track alist.
ID, TITLE, URL, DURATION, ARTIST, ALBUM, THUMBNAIL-URL, SOURCE-ID,
and SOURCE-KIND are stored as stable track fields."
  (list (cons :id id)
        (cons :title title)
        (cons :url url)
        (cons :duration duration)
        (cons :artist artist)
        (cons :album album)
        (cons :thumbnail-url thumbnail-url)
        (cons :source-id source-id)
        (cons :source-kind source-kind)))

(cl-defun ytm-radio--make-source (&key id kind title url tracks items)
  "Return a source alist from ID, KIND, TITLE, URL, TRACKS, and ITEMS."
  (list (cons :id id)
        (cons :kind kind)
        (cons :title title)
        (cons :url url)
        (cons :tracks tracks)
        (cons :items items)))

(cl-defun ytm-radio--make-player
    (&key (status 'idle) current-track process ipc-process socket position duration)
  "Return a player alist.
STATUS, CURRENT-TRACK, PROCESS, IPC-PROCESS, SOCKET, POSITION and
DURATION are ephemeral runtime fields."
  (list (cons :status status)
        (cons :current-track current-track)
        (cons :process process)
        (cons :ipc-process ipc-process)
        (cons :socket socket)
        (cons :position position)
        (cons :duration duration)))

(cl-defun ytm-radio--make-state (&key sources last-track-id)
  "Return the durable package state from SOURCES and LAST-TRACK-ID."
  (list (cons :sources sources)
        (cons :last-track-id last-track-id)))

(defvar ytm-radio--state (ytm-radio--make-state)
  "Durable state for sources and the last played track.")

(defvar ytm-radio--player (ytm-radio--make-player)
  "Ephemeral player state for mpv processes and sockets.")

(defvar ytm-radio--loaded nil
  "Non-nil once durable state has been loaded.")

(defconst ytm-radio--library-buffer-name "*ytm-radio*"
  "Buffer name for the ytm-radio browser.")

(defconst ytm-radio--now-playing-buffer-name "*ytm-radio-now-playing*"
  "Buffer name for the ytm-radio now-playing child frame.")

(defvar ytm-radio--frame nil
  "Child frame currently showing the now-playing buffer.")

(defconst ytm-radio--frame-border-width 1
  "Width in pixels of the now-playing child-frame border.")

(defvar ytm-radio--cover-render-width nil
  "Temporary cover image width used while rendering now-playing.")

(defvar ytm-radio--inhibit-frame-fit nil
  "Non-nil means rendering should not resize the now-playing frame.")

(defvar ytm-radio--progress-render-timer nil
  "Timer used to throttle now-playing progress refreshes.")

(defvar ytm-radio--cover-downloads (make-hash-table :test #'equal)
  "Cover image URLs currently being fetched into the local cache.")

(defun ytm-radio--sources ()
  "Return the current source alist."
  (or (map-elt ytm-radio--state :sources) nil))

(defun ytm-radio--source (id)
  "Return the source with ID, or nil."
  (cdr (assoc id (ytm-radio--sources))))

(defun ytm-radio--put-source (source)
  "Insert or replace SOURCE in `ytm-radio--state'."
  (let* ((id (map-elt source :id))
         (sources (ytm-radio--sources))
         (cell (assoc id sources)))
    (if cell
        (setcdr cell source)
      (setq sources (append sources (list (cons id source))))
      (setf (map-elt ytm-radio--state :sources) sources))))

(defun ytm-radio--all-tracks ()
  "Return all known tracks in source order."
  (seq-mapcat (lambda (source)
                (or (map-elt source :tracks) nil))
              (map-values (ytm-radio--sources))
              'list))

(defun ytm-radio--empty-catalog-p ()
  "Return non-nil when no source has been added."
  (null (ytm-radio--sources)))

(defun ytm-radio--track (id)
  "Return the known track with ID, or nil."
  (seq-find (lambda (track)
              (equal (map-elt track :id) id))
            (ytm-radio--all-tracks)))

(defun ytm-radio--current-track ()
  "Return the current player track, falling back to the last track."
  (or (map-elt ytm-radio--player :current-track)
      (ytm-radio--track (map-elt ytm-radio--state :last-track-id))))

(defun ytm-radio--save ()
  "Persist durable state to `ytm-radio-state-file'."
  (make-directory (file-name-directory ytm-radio-state-file) t)
  (with-temp-file ytm-radio-state-file
    (prin1 (list (cons :version 1)
                 (cons :sources (map-elt ytm-radio--state :sources))
                 (cons :last-track-id
                       (map-elt ytm-radio--state :last-track-id)))
           (current-buffer))))

(defun ytm-radio--load ()
  "Load durable state from `ytm-radio-state-file'."
  (when (file-exists-p ytm-radio-state-file)
    (let ((data (with-temp-buffer
                  (insert-file-contents ytm-radio-state-file)
                  (read (current-buffer)))))
      (setq ytm-radio--state
            (ytm-radio--make-state
             :sources (map-elt data :sources)
             :last-track-id (map-elt data :last-track-id))))))

(defun ytm-radio--ensure-loaded ()
  "Load durable state once for the current Emacs session."
  (unless ytm-radio--loaded
    (ytm-radio--load)
    (setq ytm-radio--loaded t)))

;;; Source fetching

(defun ytm-radio--ensure-program (program label)
  "Signal a user error unless PROGRAM named LABEL is executable."
  (unless (or (and (file-name-absolute-p program)
                   (file-executable-p program))
              (executable-find program))
    (user-error "Cannot find %s in `exec-path'" label)))

(defun ytm-radio--trim-buffer (buffer)
  "Return BUFFER contents without surrounding whitespace."
  (with-current-buffer buffer
    (string-trim (buffer-string))))

(defun ytm-radio--trim-file (file)
  "Return FILE contents without surrounding whitespace."
  (if (and file (file-readable-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (string-trim (buffer-string)))
    ""))

(defun ytm-radio--process-diagnostic (stdout stderr-file)
  "Return diagnostic text from STDERR-FILE, falling back to STDOUT."
  (let ((diagnostic (ytm-radio--trim-file stderr-file)))
    (if (string-empty-p diagnostic)
        (let ((fallback (ytm-radio--trim-buffer stdout)))
          (if (string-empty-p fallback)
              "no diagnostic output"
            fallback))
      diagnostic)))

(defun ytm-radio--call-json-process (program arguments failure-message)
  "Run PROGRAM with ARGUMENTS and return parsed JSON stdout.
FAILURE-MESSAGE is a function called with diagnostic text when PROGRAM
exits with a non-zero status."
  (let ((stdout (generate-new-buffer " *ytm-radio-stdout*"))
        (stderr-file (make-temp-file "ytm-radio-stderr-")))
    (unwind-protect
        (let ((exit-code
               (apply #'call-process
                      program nil (list stdout stderr-file) nil arguments)))
          (if (zerop exit-code)
              (with-current-buffer stdout
                (goto-char (point-min))
                (condition-case error
                    (json-parse-buffer :object-type 'alist
                                       :array-type 'list
                                       :null-object nil
                                       :false-object nil)
                  (error
                   (user-error "Process returned invalid JSON: %s"
                               (error-message-string error)))))
            (funcall failure-message
                     (ytm-radio--process-diagnostic stdout stderr-file))))
      (kill-buffer stdout)
      (delete-file stderr-file))))

(defun ytm-radio--call-yt-dlp (url)
  "Fetch URL metadata from yt-dlp and return parsed JSON."
  (ytm-radio--ensure-program ytm-radio-yt-dlp-program "yt-dlp")
  (ytm-radio--call-json-process
   ytm-radio-yt-dlp-program
   (append ytm-radio-yt-dlp-extra-args
           (list "--flat-playlist"
                 "--dump-single-json"
                 url))
   (lambda (diagnostic)
     (user-error "Yt-dlp failed for %s: %s" url diagnostic))))

(defun ytm-radio--url-host (url)
  "Return the host component of URL, or an empty string."
  (or (url-host (url-generic-parse-url url)) ""))

(defun ytm-radio--music-url-p (url)
  "Return non-nil when URL points at YouTube Music."
  (string-match-p "\\(?:\\`\\|\\.\\)music\\.youtube\\.com\\'"
                  (ytm-radio--url-host url)))

(defun ytm-radio--url-has-query-key-p (url key)
  "Return non-nil when URL has query parameter KEY."
  (let ((query (url-filename (url-generic-parse-url url))))
    (and query
         (string-match-p
          (concat "[?&]" (regexp-quote key) "=")
          query))))

(defun ytm-radio--source-kind (url json)
  "Return a source kind for URL and yt-dlp JSON."
  (cond ((ytm-radio--music-url-p url)
         (if (or (map-elt json 'entries)
                 (ytm-radio--url-has-query-key-p url "list"))
             'youtube-music-playlist
           'youtube-music-track))
        ((string-match-p "/@" url)
         'youtube-channel)
        ((or (map-elt json 'entries)
             (ytm-radio--url-has-query-key-p url "list"))
         'youtube-playlist)
        (t 'youtube-track)))

(defun ytm-radio--fallback-track-url (source-url id)
  "Return a watch URL for ID using SOURCE-URL to pick the host."
  (format "https://%s/watch?v=%s"
          (if (ytm-radio--music-url-p source-url)
              "music.youtube.com"
            "www.youtube.com")
          id))

(defun ytm-radio--best-thumbnail-url (json)
  "Return the best thumbnail URL in JSON, or nil."
  (or (map-elt json 'thumbnail)
      (when-let* ((thumbnails (map-elt json 'thumbnails))
                  (last-thumbnail (car (last thumbnails))))
        (map-elt last-thumbnail 'url))))

(defun ytm-radio--track-url (json source-url)
  "Return the playable URL for JSON from SOURCE-URL."
  (let ((url (or (map-elt json 'webpage_url)
                 (map-elt json 'original_url)
                 (map-elt json 'url))))
    (cond ((and (stringp url)
                (string-match-p "\\`https?://" url))
           url)
          ((map-elt json 'id)
           (ytm-radio--fallback-track-url source-url (map-elt json 'id)))
          (t source-url))))

(defun ytm-radio--track-from-json (json source-id source-kind source-url)
  "Return a track from JSON.
SOURCE-ID and SOURCE-KIND identify the owner.  SOURCE-URL is used to
build a watch URL when yt-dlp returns only a video id."
  (ytm-radio--make-track
   :id (or (map-elt json 'id) (ytm-radio--track-url json source-url))
   :title (or (map-elt json 'title)
              (map-elt json 'track)
              (map-elt json 'fulltitle)
              "")
   :url (ytm-radio--track-url json source-url)
   :duration (map-elt json 'duration)
   :artist (or (map-elt json 'artist)
               (map-elt json 'uploader)
               (map-elt json 'channel))
   :album (map-elt json 'album)
   :thumbnail-url (ytm-radio--best-thumbnail-url json)
   :source-id source-id
   :source-kind source-kind))

(defun ytm-radio--source-id (json url)
  "Return a stable source id from JSON and URL."
  (or (map-elt json 'playlist_id)
      (map-elt json 'channel_id)
      (map-elt json 'id)
      url))

(defun ytm-radio--source-title-from-json (json url)
  "Return a display title from JSON and URL."
  (or (map-elt json 'title)
      (map-elt json 'playlist_title)
      (map-elt json 'channel)
      url))

(defun ytm-radio--source-from-json (json url)
  "Normalize yt-dlp JSON from URL into a source alist."
  (let* ((id (ytm-radio--source-id json url))
         (kind (ytm-radio--source-kind url json))
         (entries (or (map-elt json 'entries) (list json)))
         (tracks (seq-keep
                  (lambda (entry)
                    (when (and entry
                               (or (map-elt entry 'id)
                                   (map-elt entry 'url)
                                   (not (map-elt json 'entries))))
                      (ytm-radio--track-from-json entry id kind url)))
                  entries)))
    (ytm-radio--make-source
     :id id
     :kind kind
     :title (ytm-radio--source-title-from-json json url)
     :url url
     :tracks tracks
     :items tracks)))

(defun ytm-radio--fetch-source (url)
  "Fetch URL through yt-dlp and return a normalized source."
  (ytm-radio--source-from-json (ytm-radio--call-yt-dlp url) url))

;;; Account helper

(defun ytm-radio--ensure-readable-file (file label)
  "Signal a user error unless FILE named LABEL is readable."
  (unless (and file (file-readable-p file))
    (user-error "%s is not configured or readable" label)))

(defun ytm-radio--helper-limit (target)
  "Return the configured helper limit for TARGET."
  (if (equal target "home")
      ytm-radio-helper-home-limit
    ytm-radio-helper-library-limit))

(defun ytm-radio--helper-browse-arguments (target)
  "Return helper arguments for browsing TARGET."
  (append (list "browse" target)
          (when ytm-radio-helper-auth-file
            (list "--auth" (expand-file-name ytm-radio-helper-auth-file)))
          (when ytm-radio-helper-use-mock-data
            (list "--mock"))
          (list "--limit"
                (number-to-string (ytm-radio--helper-limit target)))))

(defun ytm-radio--helper-import-browser-arguments (browser output)
  "Return helper arguments for importing BROWSER cookies into OUTPUT."
  (list "auth"
        "import-browser"
        "--browser"
        browser
        "--output"
        (expand-file-name output)
        "--yt-dlp"
        ytm-radio-yt-dlp-program))

(defun ytm-radio--helper-import-headers-arguments (input output)
  "Return helper arguments for importing request headers from INPUT into OUTPUT."
  (list "auth"
        "import-headers"
        "--input"
        (expand-file-name input)
        "--output"
        (expand-file-name output)))

(defun ytm-radio--helper-import-dia-arguments (output &optional restart)
  "Return helper arguments for importing Dia login into OUTPUT.
When RESTART is non-nil, allow the helper to restart Dia once."
  (append (list "auth"
                "import-dia"
                "--output"
                (expand-file-name output)
                "--port"
                (number-to-string ytm-radio-helper-dia-cdp-port)
                "--app"
                (expand-file-name ytm-radio-helper-dia-app))
          (when restart
            (list "--restart"))))

(defun ytm-radio--auth-import-candidates ()
  "Return login source candidates for `ytm-radio-auth-import'."
  (delete-dups (append ytm-radio-helper-browser-candidates
                       (list "dia"))))

(defun ytm-radio--dia-auth-source-p (source)
  "Return non-nil when SOURCE names Dia."
  (string-equal (downcase (string-trim source)) "dia"))

(defun ytm-radio--call-helper (arguments)
  "Run the external helper with ARGUMENTS and return parsed JSON."
  (ytm-radio--ensure-program ytm-radio-helper-command "ytm-radio-helper")
  (ytm-radio--call-json-process
   ytm-radio-helper-command
   arguments
   (lambda (diagnostic)
     (user-error "Account helper failed: %s" diagnostic))))

(defun ytm-radio--helper-envelope-data (envelope)
  "Return the data alist from helper ENVELOPE."
  (unless (map-elt envelope 'ok)
    (user-error "Account helper returned an error"))
  (unless (equal (map-elt envelope 'schema) 1)
    (user-error "Unsupported helper schema %S" (map-elt envelope 'schema)))
  (or (map-elt envelope 'data)
      (user-error "Account helper returned no data")))

(defun ytm-radio--symbol-value (value fallback)
  "Return VALUE as a symbol, or FALLBACK when VALUE is absent."
  (cond ((symbolp value) value)
        ((stringp value) (intern value))
        (t fallback)))

(defun ytm-radio--track-from-helper-item (item source-id source-kind)
  "Return a ytm-radio track from helper ITEM.
SOURCE-ID and SOURCE-KIND identify the imported helper source."
  (ytm-radio--make-track
   :id (map-elt item 'id)
   :title (map-elt item 'title)
   :url (map-elt item 'url)
   :duration (map-elt item 'duration)
   :artist (map-elt item 'artist)
   :album (map-elt item 'album)
   :thumbnail-url (map-elt item 'thumbnail-url)
   :source-id source-id
   :source-kind source-kind))

(defun ytm-radio--helper-track-item-p (item)
  "Return non-nil when helper ITEM is a playable track."
  (and item
       (equal (or (map-elt item 'type) "track") "track")
       (map-elt item 'url)))

(defun ytm-radio--source-from-helper (source)
  "Return a ytm-radio source from helper SOURCE."
  (let* ((id (map-elt source 'id))
         (kind (ytm-radio--symbol-value (map-elt source 'kind)
                                        'account))
         (items (or (map-elt source 'items)
                    (map-elt source 'tracks)
                    nil))
         (tracks (seq-keep
                  (lambda (item)
                    (when (ytm-radio--helper-track-item-p item)
                      (ytm-radio--track-from-helper-item item id kind)))
                  items)))
    (ytm-radio--make-source
     :id id
     :kind kind
     :title (map-elt source 'title)
     :url (map-elt source 'url)
     :tracks tracks
     :items items)))

(defun ytm-radio--helper-sources (data)
  "Return normalized sources from helper DATA."
  (seq-keep #'ytm-radio--source-from-helper
            (or (map-elt data 'sources) nil)))

(defun ytm-radio--helper-target-source-p (source target)
  "Return non-nil when SOURCE belongs to helper TARGET."
  (let ((id (or (map-elt source :id) ""))
        (kind (symbol-name (or (map-elt source :kind) 'unknown))))
    (pcase target
      ("home"
       (or (string-prefix-p "ytm:home" id)
           (member kind '("youtube-music-home"
                          "youtube-music-home-section"))))
      ("library"
       (or (string-prefix-p "ytm:library:songs" id)
           (string-equal kind "youtube-music-library")))
      ("liked"
       (or (string-prefix-p "ytm:library:liked" id)
           (string-equal kind "youtube-music-liked")))
      (_ nil))))

(defun ytm-radio--drop-helper-target-sources (target)
  "Remove existing helper sources for TARGET from state."
  (setf (map-elt ytm-radio--state :sources)
        (seq-remove
         (lambda (cell)
           (ytm-radio--helper-target-source-p (cdr cell) target))
         (ytm-radio--sources))))

(defun ytm-radio--import-sources (sources)
  "Import SOURCES into state and return the number imported."
  (dolist (source sources)
    (ytm-radio--put-source source))
  (ytm-radio--save)
  (ytm-radio--render)
  (length sources))

(defun ytm-radio--import-helper-target (target label)
  "Import helper TARGET and report LABEL."
  (ytm-radio--ensure-loaded)
  (unless ytm-radio-helper-use-mock-data
    (ytm-radio--ensure-readable-file
     ytm-radio-helper-auth-file
     "YouTube Music helper auth file"))
  (let* ((sources (ytm-radio--helper-sources
                   (ytm-radio--helper-envelope-data
                    (ytm-radio--call-helper
                     (ytm-radio--helper-browse-arguments target)))))
         (track-count (seq-reduce
                       (lambda (count source)
                         (+ count (length (map-elt source :tracks))))
                       sources
                       0)))
    (unless sources
      (user-error "No %s returned" label))
    (ytm-radio--drop-helper-target-sources target)
    (ytm-radio--import-sources sources)
    (message "Imported %s: %d sources, %d tracks"
             label
             (length sources)
             track-count)))

;;; Playback

(defun ytm-radio--mpv-raw-options-argument ()
  "Return the mpv ytdl raw options argument, or nil."
  (when ytm-radio-ytdl-raw-options
    (concat "--ytdl-raw-options="
            (mapconcat #'identity ytm-radio-ytdl-raw-options ","))))

(defun ytm-radio--mpv-arguments (socket url)
  "Return mpv arguments for SOCKET and media URL."
  (append ytm-radio-mpv-extra-args
          (delq nil (list (ytm-radio--mpv-raw-options-argument)
                          "--no-video"
                          (concat "--input-ipc-server=" socket)
                          url))))

(defun ytm-radio--set-status (status)
  "Set player STATUS and refresh the UI."
  (setf (map-elt ytm-radio--player :status) status)
  (ytm-radio--render))

(defun ytm-radio--stop-process ()
  "Stop the current mpv process and IPC connection."
  (let ((process (map-elt ytm-radio--player :process))
        (ipc-process (map-elt ytm-radio--player :ipc-process)))
    (ytm-radio--cancel-progress-render)
    (setf (map-elt ytm-radio--player :process) nil
          (map-elt ytm-radio--player :ipc-process) nil
          (map-elt ytm-radio--player :socket) nil
          (map-elt ytm-radio--player :position) nil
          (map-elt ytm-radio--player :duration) nil
          (map-elt ytm-radio--player :status) 'stopped)
    (when (process-live-p ipc-process)
      (delete-process ipc-process))
    (when (process-live-p process)
      (delete-process process))))

(defun ytm-radio--play-track (track)
  "Play TRACK with mpv."
  (ytm-radio--ensure-program ytm-radio-mpv-program "mpv")
  (unless (map-elt track :url)
    (user-error "Track has no playable URL"))
  (ytm-radio--stop-process)
  (let* ((socket (make-temp-name
                  (file-name-concat temporary-file-directory "ytm-radio-mpv-")))
         (args (ytm-radio--mpv-arguments socket (map-elt track :url)))
         (process (apply #'start-process
                         "ytm-radio-mpv" nil ytm-radio-mpv-program args)))
    (set-process-sentinel process #'ytm-radio--mpv-sentinel)
    (setf (map-elt ytm-radio--player :process) process
          (map-elt ytm-radio--player :socket) socket
          (map-elt ytm-radio--player :current-track) track
          (map-elt ytm-radio--player :status) 'loading
          (map-elt ytm-radio--player :position) nil
          (map-elt ytm-radio--player :duration) (map-elt track :duration)
          (map-elt ytm-radio--state :last-track-id) (map-elt track :id))
    (ytm-radio--save)
    (ytm-radio--mpv-connect socket process 0)
    (ytm-radio--render)
    (ytm-radio--show-now-playing nil)))

(defun ytm-radio--mpv-connect (socket process attempt)
  "Connect to mpv SOCKET for PROCESS, retrying from ATTEMPT."
  (when (and (< attempt 40)
             (process-live-p process)
             (eq process (map-elt ytm-radio--player :process)))
    (condition-case nil
        (let ((ipc (make-network-process
                    :name "ytm-radio-mpv-ipc"
                    :family 'local
                    :service socket
                    :coding 'utf-8
                    :noquery t
                    :filter #'ytm-radio--mpv-filter)))
          (process-put ipc 'pending "")
          (process-put ipc 'request-id 0)
          (process-put ipc 'callbacks (make-hash-table :test 'eql))
          (setf (map-elt ytm-radio--player :ipc-process) ipc)
          (ytm-radio--mpv-send (list "observe_property" 1 "pause"))
          (ytm-radio--mpv-send (list "observe_property" 2 "core-idle"))
          (ytm-radio--mpv-send (list "observe_property" 3 "time-pos"))
          (ytm-radio--mpv-send (list "observe_property" 4 "duration")))
      (error
       (run-at-time 0.05 nil
                    #'ytm-radio--mpv-connect socket process (1+ attempt))))))

(defun ytm-radio--mpv-send (command)
  "Send COMMAND to the current mpv IPC process."
  (when-let* ((ipc (map-elt ytm-radio--player :ipc-process))
              ((process-live-p ipc)))
    (process-send-string
     ipc
     (concat (json-encode (list (cons 'command command))) "\n"))))

(defun ytm-radio--render-now-playing-without-fit ()
  "Render the now-playing buffer without resizing its child frame."
  (let ((ytm-radio--inhibit-frame-fit t))
    (ytm-radio--render-now-playing)))

(defun ytm-radio--run-progress-render ()
  "Run a pending throttled progress refresh."
  (setq ytm-radio--progress-render-timer nil)
  (ytm-radio--render-now-playing-without-fit))

(defun ytm-radio--schedule-progress-render ()
  "Schedule a throttled now-playing progress refresh."
  (unless (timerp ytm-radio--progress-render-timer)
    (setq ytm-radio--progress-render-timer
          (run-at-time 0.5 nil #'ytm-radio--run-progress-render))))

(defun ytm-radio--cancel-progress-render ()
  "Cancel any pending now-playing progress refresh."
  (when (timerp ytm-radio--progress-render-timer)
    (cancel-timer ytm-radio--progress-render-timer)
    (setq ytm-radio--progress-render-timer nil)))

(defun ytm-radio--set-playback-property (property value)
  "Set playback PROPERTY to VALUE and refresh the now-playing view."
  (setf (map-elt ytm-radio--player property) value)
  (if (eq property :position)
      (ytm-radio--schedule-progress-render)
    (ytm-radio--render-now-playing-without-fit)))

(defun ytm-radio--mpv-filter (process output)
  "Parse newline-delimited JSON OUTPUT from mpv PROCESS."
  (let ((pending (concat (process-get process 'pending) output)))
    (while (string-match "\n" pending)
      (ytm-radio--mpv-dispatch process
                               (substring pending 0 (match-beginning 0)))
      (setq pending (substring pending (match-end 0))))
    (process-put process 'pending pending)))

(defun ytm-radio--mpv-dispatch (_process line)
  "Dispatch one mpv JSON message LINE."
  (when-let* ((msg (ignore-errors
                     (json-parse-string line
                                        :object-type 'alist
                                        :null-object nil
                                        :false-object nil)))
              (event (map-elt msg 'event)))
    (ytm-radio--mpv-event event msg)))

(defun ytm-radio--mpv-event (event msg)
  "Mirror mpv EVENT and MSG into player state."
  (pcase event
    ("property-change"
     (pcase (map-elt msg 'name)
       ("pause"
        (ytm-radio--set-status (if (map-elt msg 'data) 'paused 'playing)))
       ("core-idle"
        (when (not (map-elt msg 'data))
          (ytm-radio--set-status 'playing)))
       ("time-pos"
        (ytm-radio--set-playback-property :position (map-elt msg 'data)))
       ("duration"
        (ytm-radio--set-playback-property :duration (map-elt msg 'data)))))
    ("end-file"
     (when (equal (map-elt msg 'reason) "error")
       (ytm-radio--set-status 'stopped)
       (message "Playback error: %s"
                (or (map-elt msg 'file_error) "unknown error"))))))

(defun ytm-radio--mpv-sentinel (process _event)
  "Advance when mpv PROCESS exits cleanly."
  (when (and (not (process-live-p process))
             (eq process (map-elt ytm-radio--player :process)))
    (if-let* ((current (map-elt ytm-radio--player :current-track))
              (next (and (zerop (process-exit-status process))
                         (ytm-radio--next-track current))))
        (ytm-radio--play-track next)
      (ytm-radio--stop-process)
      (ytm-radio--render))))

(defun ytm-radio--neighbor-track (track direction)
  "Return TRACK's neighbor in DIRECTION, either `next' or `previous'."
  (let ((tracks (ytm-radio--all-tracks)))
    (pcase direction
      ('next
       (seq-first
        (cdr (seq-drop-while
              (lambda (other)
                (not (equal (map-elt other :id) (map-elt track :id))))
              tracks))))
      ('previous
       (seq-first
        (seq-reverse
         (seq-take-while
          (lambda (other)
            (not (equal (map-elt other :id) (map-elt track :id))))
          tracks)))))))

(defun ytm-radio--next-track (track)
  "Return the known track after TRACK."
  (ytm-radio--neighbor-track track 'next))

(defun ytm-radio--previous-track (track)
  "Return the known track before TRACK."
  (ytm-radio--neighbor-track track 'previous))

;;; UI

(defvar ytm-radio--mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'ytm-radio-add-url)
    (define-key map (kbd "A") #'ytm-radio-auth-import)
    (define-key map (kbd "c") #'ytm-radio-now-playing)
    (define-key map (kbd "L") #'ytm-radio-import-ytmusic-library)
    (define-key map (kbd "i") #'ytm-radio-import-ytmusic-liked)
    (define-key map (kbd "r") #'ytm-radio-import-ytmusic-home)
    (define-key map (kbd "/") #'ytm-radio-play-track)
    (define-key map (kbd "s") #'ytm-radio-play-source)
    (define-key map (kbd "SPC") #'ytm-radio-toggle-pause)
    (define-key map (kbd "n") #'ytm-radio-next)
    (define-key map (kbd "p") #'ytm-radio-previous)
    (define-key map (kbd "S") #'ytm-radio-share)
    (define-key map (kbd "f") #'ytm-radio-seek-forward)
    (define-key map (kbd "b") #'ytm-radio-seek-backward)
    (define-key map (kbd "q") #'ytm-radio-hide)
    map)
  "Keymap for `ytm-radio--mode'.")

(define-derived-mode ytm-radio--mode special-mode "ytm-radio"
  "Major mode for the ytm-radio browser buffer."
  (setq-local mode-line-format nil))

(defvar ytm-radio--now-playing-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'ytm-radio-toggle-pause)
    (define-key map (kbd "n") #'ytm-radio-next)
    (define-key map (kbd "p") #'ytm-radio-previous)
    (define-key map (kbd "S") #'ytm-radio-share)
    (define-key map (kbd "q") #'ytm-radio-hide)
    (dolist (command '(scroll-up-command scroll-down-command
                       scroll-up scroll-down scroll-left scroll-right
                       mwheel-scroll pixel-scroll-precision))
      (define-key map (vector 'remap command) #'ignore))
    map)
  "Keymap for `ytm-radio--now-playing-mode'.")

(define-derived-mode ytm-radio--now-playing-mode special-mode "ytm-radio-now"
  "Major mode for the ytm-radio now-playing child frame."
  (setq-local mode-line-format nil)
  (setq-local cursor-type nil)
  (setq-local truncate-lines nil)
  (setq-local overflow-newline-into-fringe t)
  (setq-local fringe-indicator-alist
              (assq-delete-all
               'continuation
               (assq-delete-all 'truncation
                                (copy-tree fringe-indicator-alist))))
  (setq-local left-fringe-width 0)
  (setq-local right-fringe-width 0)
  (setq-local vertical-scroll-bar nil)
  (setq-local horizontal-scroll-bar nil)
  (setq-local indicate-buffer-boundaries nil)
  (setq-local indicate-empty-lines nil)
  (setq-local cursor-in-non-selected-windows nil)
  (add-hook 'window-scroll-functions #'ytm-radio--prevent-scroll nil t))

(defun ytm-radio--prevent-scroll (window start)
  "Keep WINDOW pinned to the top when START is moved by scrolling."
  (when (> start (point-min))
    (set-window-start window (point-min) t)))

(defun ytm-radio--buffer ()
  "Return the ytm-radio browser buffer, creating it when needed."
  (let ((buffer (get-buffer-create ytm-radio--library-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ytm-radio--mode)
        (ytm-radio--mode)))
    buffer))

(defun ytm-radio--now-playing-buffer ()
  "Return the now-playing buffer, creating it when needed."
  (let ((buffer (get-buffer-create ytm-radio--now-playing-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ytm-radio--now-playing-mode)
        (ytm-radio--now-playing-mode)))
    buffer))

(defun ytm-radio--track-title (track)
  "Return TRACK's display title."
  (or (and-let* ((title (map-elt track :title))
                 ((not (string-empty-p title))))
        title)
      (map-elt track :id)
      "Untitled"))

(defun ytm-radio--source-display-title (source)
  "Return SOURCE's display title."
  (or (map-elt source :title)
      (map-elt source :id)
      "Untitled source"))

(defun ytm-radio--track-label (track)
  "Return the completion label for TRACK."
  (let* ((source (ytm-radio--source (map-elt track :source-id)))
         (source-title (if source
                           (ytm-radio--source-display-title source)
                         (or (map-elt track :source-id) "Unknown source"))))
    (format "%s - %s" source-title (ytm-radio--track-title track))))

(defun ytm-radio--format-status ()
  "Return the current player status as a string."
  (symbol-name (or (map-elt ytm-radio--player :status) 'idle)))

(defun ytm-radio--format-duration (seconds)
  "Return SECONDS as a compact duration string."
  (when (numberp seconds)
    (setq seconds (floor seconds))
    (if (>= seconds 3600)
        (format "%d:%02d:%02d"
                (/ seconds 3600)
                (% (/ seconds 60) 60)
                (% seconds 60))
      (format "%d:%02d" (/ seconds 60) (% seconds 60)))))

(defun ytm-radio--progress-bar (position duration width)
  "Return a Unicode progress bar for POSITION, DURATION, and WIDTH."
  (when (and (numberp duration)
             (> duration 0)
             (>= width 5))
    (let* ((position (if (numberp position)
                         (min duration (max 0 position))
                       0))
           (ratio (/ (float position) duration))
           (cursor (min (1- width)
                        (floor (* ratio width)))))
      (concat
       (propertize (make-string cursor ?━) 'face 'bold)
       (propertize "●" 'face 'bold)
       (propertize (make-string (- width cursor 1) ?━) 'face 'shadow)))))

(defun ytm-radio--progress-bar-width (left-label right-label)
  "Return a progress bar width that fits between LEFT-LABEL and RIGHT-LABEL."
  (let ((available (- (ytm-radio--now-playing-text-width)
                      (string-width left-label)
                      (string-width right-label)
                      4)))
    (when (>= available 5)
      (min 10 available))))

(defun ytm-radio--playback-time-label (track)
  "Return a compact playback time label for TRACK, or nil."
  (let* ((position (map-elt ytm-radio--player :position))
         (duration (or (map-elt ytm-radio--player :duration)
                       (map-elt track :duration)))
         (position-label (ytm-radio--format-duration position))
         (duration-label (ytm-radio--format-duration duration))
         (left-label (or position-label "0:00")))
    (cond
     (duration-label
      (if-let* ((bar-width (ytm-radio--progress-bar-width left-label
                                                          duration-label))
                (bar (ytm-radio--progress-bar position duration bar-width)))
          (format "%s  %s  %s" left-label bar duration-label)
        (if position-label
            (format "%s / %s" position-label duration-label)
          duration-label)))
     (position-label
      position-label))))

(defun ytm-radio--item-title (item)
  "Return ITEM's display title."
  (or (map-elt item 'title)
      (map-elt item :title)
      (map-elt item 'id)
      (map-elt item :id)
      "Untitled"))

(defun ytm-radio--item-type (item)
  "Return ITEM's display type."
  (or (map-elt item 'type)
      (map-elt item :type)
      (when (or (map-elt item :source-id)
                (ytm-radio--helper-track-item-p item))
        "track")
      "item"))

(defun ytm-radio--item-url (item)
  "Return ITEM's URL, if any."
  (or (map-elt item 'url)
      (map-elt item :url)))

(defun ytm-radio--item-detail (item)
  "Return compact secondary text for ITEM."
  (string-join
   (delq nil
         (list (or (map-elt item 'artist) (map-elt item :artist))
               (or (map-elt item 'album) (map-elt item :album))
               (or (map-elt item 'subtitle) (map-elt item :subtitle))
               (ytm-radio--format-duration
                (or (map-elt item 'duration) (map-elt item :duration)))))
   " - "))

(defun ytm-radio--item-summary (item)
  "Return a one-line summary for ITEM."
  (string-join
   (delq nil
         (list (ytm-radio--item-type item)
               (let ((detail (ytm-radio--item-detail item)))
                 (unless (string-empty-p detail)
                   detail))))
   " | "))

(defun ytm-radio--truncate (text width)
  "Return TEXT truncated to WIDTH display columns."
  (truncate-string-to-width (or text "") width nil nil "..."))

(defun ytm-radio--item-id (item)
  "Return ITEM's id, if any."
  (or (map-elt item 'id)
      (map-elt item :id)))

(defun ytm-radio--item-thumbnail-url (item)
  "Return ITEM's thumbnail URL, deriving a YouTube fallback when possible."
  (or (map-elt item 'thumbnail-url)
      (map-elt item :thumbnail-url)
      (when (string-equal (ytm-radio--item-type item) "track")
        (when-let* ((id (ytm-radio--item-id item))
                    ((string-match-p "\\`[[:alnum:]_-]+\\'" id)))
          (format "https://i.ytimg.com/vi/%s/hqdefault.jpg" id)))))

(defun ytm-radio--insert-button (label command)
  "Insert a text button with LABEL running COMMAND."
  (insert-text-button label
                      'action (lambda (_button)
                                (call-interactively command))
                      'follow-link t))

(defun ytm-radio--insert-action-button (label action)
  "Insert a text button with LABEL running ACTION."
  (insert-text-button label
                      'action (lambda (_button)
                                (funcall action))
                      'follow-link t))

(defun ytm-radio--item-track (item source)
  "Return ITEM as a track owned by SOURCE, or nil."
  (cond
   ((map-elt item :source-id)
    item)
   ((ytm-radio--helper-track-item-p item)
    (ytm-radio--track-from-helper-item
     item
     (map-elt source :id)
     (or (map-elt source :kind) 'account)))))

(defun ytm-radio--play-source-object (source)
  "Play the first track in SOURCE."
  (let ((track (car (map-elt source :tracks))))
    (unless track
      (user-error "Source has no playable tracks"))
    (ytm-radio--play-track track)))

(defun ytm-radio--insert-item-thumbnail (item)
  "Insert ITEM's thumbnail image when available and return non-nil."
  (when-let* ((url (ytm-radio--item-thumbnail-url item))
              ((display-graphic-p))
              (file (ytm-radio--ensure-cover-file
                     url
                     (lambda (_url _file)
                       (ytm-radio--render-browser))))
              (image (ignore-errors
                       (create-image file nil nil
                                     :max-width ytm-radio-browser-thumbnail-size
                                     :max-height ytm-radio-browser-thumbnail-size
                                     :ascent 'center))))
    (insert-image image "thumbnail")
    t))

(defun ytm-radio--insert-source-item (source item index)
  "Insert ITEM from SOURCE at one-based INDEX."
  (let* ((title (ytm-radio--truncate (ytm-radio--item-title item) 40))
         (summary (ytm-radio--truncate (ytm-radio--item-summary item) 72))
         (url (ytm-radio--item-url item))
         (track (ytm-radio--item-track item source)))
    (insert "  ")
    (if (ytm-radio--insert-item-thumbnail item)
        (insert "  ")
      (insert (propertize "      " 'face 'shadow)))
    (insert (propertize (format "%02d " index) 'face 'shadow))
    (cond
     (track
      (ytm-radio--insert-action-button
       title
       (lambda () (ytm-radio--play-track track))))
     (url
      (ytm-radio--insert-action-button
       title
       (lambda () (ytm-radio-add-url url))))
     (t
      (insert title)))
    (unless (string-empty-p summary)
      (insert "  " (propertize summary 'face 'shadow)))
    (insert "\n")))

(defun ytm-radio--source-items (source)
  "Return display items for SOURCE."
  (or (map-elt source :items)
      (map-elt source :tracks)
      nil))

(defun ytm-radio--render ()
  "Render all visible ytm-radio buffers."
  (ytm-radio--render-browser)
  (ytm-radio--render-now-playing))

(defun ytm-radio--render-browser ()
  "Render the current package state into the browser buffer."
  (when-let* ((buffer (get-buffer ytm-radio--library-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (track (ytm-radio--current-track)))
        (erase-buffer)
        (insert (propertize "ytm-radio" 'face 'bold)
                "  "
                (propertize (ytm-radio--format-status) 'face 'shadow)
                "\n")
        (if track
            (insert (ytm-radio--track-label track) "\n")
          (insert "No track\n"))
        (insert (propertize (format "%d sources" (length (ytm-radio--sources)))
                            'face 'shadow)
                "\n")
        (when (ytm-radio--empty-catalog-p)
          (insert "\nAdd a URL, or import your YouTube Music library/home.\n")
          (insert "Use login once to import a browser session.\n"))
        (insert "\n\n")
        (if (ytm-radio--empty-catalog-p)
            (insert "No YouTube Music pages imported yet.\n")
          (insert "Browse\n")
          (dolist (source (map-values (ytm-radio--sources)))
            (let ((source source)
                  (items (ytm-radio--source-items source)))
              (insert "\n")
              (insert (propertize (ytm-radio--source-display-title source)
                                  'face 'bold))
              (insert "  "
                      (propertize
                       (format "%d items / %d tracks"
                               (length items)
                               (length (map-elt source :tracks)))
                       'face 'shadow)
                      "\n")
              (cl-loop for item in items
                       for index from 1
                       do (ytm-radio--insert-source-item source item index)))))))))

(defun ytm-radio--cover-cache-path (url)
  "Return the local cache path for cover URL, or nil."
  (when (and (stringp url)
             (string-match-p "\\`https?://" url))
    (expand-file-name (concat (secure-hash 'sha1 url) ".jpg")
                      ytm-radio-cover-cache-directory)))

(defun ytm-radio--cover-file (url)
  "Return a cached local cover file for URL, or nil."
  (when-let* ((file (ytm-radio--cover-cache-path url)))
    (when (file-readable-p file)
      file)))

(defun ytm-radio--cache-cover (url callback)
  "Fetch cover URL asynchronously and call CALLBACK with URL and file."
  (when-let* ((file (ytm-radio--cover-cache-path url)))
    (unless (or (file-readable-p file)
                (gethash url ytm-radio--cover-downloads))
      (puthash url t ytm-radio--cover-downloads)
      (condition-case nil
          (progn
            (make-directory ytm-radio-cover-cache-directory t)
            (let* ((url-show-status nil)
                   (process
                    (url-retrieve
                     url
                     (lambda (status)
                       (unwind-protect
                           (progn
                             (remhash url ytm-radio--cover-downloads)
                             (unless (plist-get status :error)
                               (goto-char (point-min))
                               (when (search-forward "\n\n" nil t)
                                 (let ((coding-system-for-write 'binary))
                                   (write-region (point) (point-max)
                                                 file nil 'silent))
                                 (when (and callback (file-readable-p file))
                                   (funcall callback url file)))))
                         (kill-buffer (current-buffer))))
                     nil t t)))
              (unless process
                (remhash url ytm-radio--cover-downloads))))
        (error
         (remhash url ytm-radio--cover-downloads))))))

(defun ytm-radio--ensure-cover-file (url callback)
  "Return cached cover file for URL, scheduling CALLBACK if it is missing."
  (or (ytm-radio--cover-file url)
      (progn
        (ytm-radio--cache-cover url callback)
        nil)))

(defun ytm-radio--scaled-cover-size (natural-width natural-height)
  "Return cover display size for NATURAL-WIDTH and NATURAL-HEIGHT."
  (let* ((natural-width (max 1 natural-width))
         (natural-height (max 1 natural-height))
         (scale (min (/ (float ytm-radio-cover-max-width) natural-width)
                     (/ (float ytm-radio-cover-max-height) natural-height))))
    (cons (max 1 (round (* natural-width scale)))
          (max 1 (round (* natural-height scale))))))

(defun ytm-radio--cover-display-size (file)
  "Return display size for cover FILE, or nil."
  (when-let* ((image (ignore-errors (create-image file nil nil)))
              (dimensions (ignore-errors
                            (image-size image t
                                        (ytm-radio--now-playing-frame)))))
    (ytm-radio--scaled-cover-size (ceiling (car dimensions))
                                  (ceiling (cdr dimensions)))))

(defun ytm-radio--cover-spec (track)
  "Return an image spec and display size for TRACK's cover."
  (when-let* ((thumbnail (ytm-radio--track-thumbnail-url track))
              (file (and (display-graphic-p)
                         (ytm-radio--ensure-cover-file
                          thumbnail
                          (lambda (url _file)
                            (when-let* ((current (ytm-radio--current-track)))
                              (when (equal url
                                           (ytm-radio--track-thumbnail-url
                                            current))
                                (ytm-radio--render-now-playing)))))))
              (size (ytm-radio--cover-display-size file))
              (image (ignore-errors
                       (create-image file nil nil
                                     :width (car size)
                                     :height (cdr size)))))
    (list image size)))

(defun ytm-radio--track-thumbnail-url (track)
  "Return TRACK's thumbnail URL, deriving a YouTube fallback when needed."
  (or (map-elt track :thumbnail-url)
      (when-let* ((id (map-elt track :id))
                  ((string-match-p "\\`[[:alnum:]_-]+\\'" id)))
        (format "https://i.ytimg.com/vi/%s/hqdefault.jpg" id))))

(defun ytm-radio--insert-cover (cover-spec)
  "Insert COVER-SPEC's image or a textual placeholder."
  (insert ytm-radio--now-playing-thin-padding)
  (if-let* ((image (car-safe cover-spec)))
      (progn
        (insert (make-string ytm-radio--cover-left-padding-columns ?\s))
        (insert-image image "cover")
        (insert "\n"))
    (insert "[cover]\n")))

(defun ytm-radio--now-playing-controls-text ()
  "Return plain fallback text width for now-playing controls."
  "  <<  ||  >>  ^  ")

(defun ytm-radio--now-playing-frame ()
  "Return the now-playing frame, or the selected frame as fallback."
  (if (frame-live-p ytm-radio--frame)
      ytm-radio--frame
    (selected-frame)))

(defun ytm-radio--now-playing-content-columns ()
  "Return the text columns used for the now-playing cover content."
  (let* ((frame (ytm-radio--now-playing-frame))
         (char-width (max 1 (frame-char-width frame)))
         (cover-width (or ytm-radio--cover-render-width
                          ytm-radio-cover-max-width))
         (cover-columns (ceiling cover-width char-width))
         (controls-columns (string-width
                            (ytm-radio--now-playing-controls-text))))
    (max 1 cover-columns controls-columns)))

(defun ytm-radio--now-playing-layout-columns ()
  "Return the total text columns used for the now-playing layout."
  (+ ytm-radio--cover-left-padding-columns
     (ytm-radio--now-playing-content-columns)))

(defun ytm-radio--now-playing-layout-columns-for-cover (cover-width frame)
  "Return layout columns needed for COVER-WIDTH pixels in FRAME."
  (let* ((char-width (max 1 (frame-char-width frame)))
         (cover-columns (ceiling cover-width char-width))
         (controls-columns (string-width
                            (ytm-radio--now-playing-controls-text))))
    (+ ytm-radio--cover-left-padding-columns
       (max 1 cover-columns controls-columns))))

(defun ytm-radio--now-playing-column-width ()
  "Return the text columns used for centered now-playing rows."
  (ytm-radio--now-playing-layout-columns))

(defun ytm-radio--now-playing-text-width ()
  "Return the text width used below the now-playing cover."
  (max 8 (ytm-radio--now-playing-column-width)))

(defun ytm-radio--insert-centered-now-playing-line (text &optional face)
  "Insert TEXT centered in the now-playing layout, optionally using FACE."
  (let* ((width (ytm-radio--now-playing-text-width))
         (text (ytm-radio--truncate text width))
         (padding (max 0 (/ (- width (string-width text)) 2))))
    (insert (make-string padding ?\s))
    (insert (if face (propertize text 'face face) text))
    (insert "\n")))

(defun ytm-radio--now-playing-control-label (icon)
  "Return a control label for ICON."
  (format "%s" icon))

(defun ytm-radio--mdicon (name fallback)
  "Return Material Design icon NAME, or FALLBACK when unavailable."
  (if (and (require 'nerd-icons nil t)
           (fboundp 'nerd-icons-mdicon))
      (condition-case nil
          (funcall #'nerd-icons-mdicon name :height 1.0)
        (error fallback))
    fallback))

(define-button-type 'ytm-radio-now-playing-button
  'follow-link t
  'face 'default
  'mouse-face 'highlight)

(defun ytm-radio--insert-now-playing-control (icon command help)
  "Insert a now-playing ICON button running COMMAND with HELP text."
  (insert-text-button (ytm-radio--now-playing-control-label icon)
                      'type 'ytm-radio-now-playing-button
                      'action (lambda (_button)
                                (call-interactively command))
                      'help-echo help
                      'face 'default
                      'mouse-face 'highlight))

(defun ytm-radio--now-playing-controls ()
  "Return now-playing transport controls as button specs."
  (list
   (list (ytm-radio--mdicon "nf-md-skip_previous" "<<")
         #'ytm-radio-previous
         "Previous track")
   (list (if (eq (map-elt ytm-radio--player :status) 'playing)
             (ytm-radio--mdicon "nf-md-pause" "||")
           (ytm-radio--mdicon "nf-md-play" ">"))
         #'ytm-radio-toggle-pause
         "Play or pause")
   (list (ytm-radio--mdicon "nf-md-skip_next" ">>")
         #'ytm-radio-next
         "Next track")
   (list (ytm-radio--mdicon "nf-md-share" "^")
         #'ytm-radio-share
         "Share track")))

(defun ytm-radio--insert-now-playing-controls ()
  "Insert centered now-playing transport controls."
  (let* ((separator "   ")
         (controls (ytm-radio--now-playing-controls))
         (labels (mapcar #'car controls))
         (controls-width (string-width (string-join labels separator)))
         (padding (max 0 (/ (- (ytm-radio--now-playing-text-width)
                              controls-width)
                           2))))
    (insert (make-string padding ?\s))
    (cl-loop for (icon command help) in controls
             for first = t then nil
             unless first do (insert separator)
             do (ytm-radio--insert-now-playing-control icon command help))))

(defun ytm-radio--render-now-playing ()
  "Render the now-playing buffer."
  (when-let* ((buffer (get-buffer ytm-radio--now-playing-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (track (ytm-radio--current-track)))
        (erase-buffer)
        (if track
            (let* ((cover-spec (ytm-radio--cover-spec track))
                   (cover-size (cadr cover-spec))
                   (ytm-radio--cover-render-width (car-safe cover-size))
                   (text-width (ytm-radio--now-playing-text-width)))
              (ytm-radio--insert-cover cover-spec)
              (ytm-radio--insert-centered-now-playing-line
               (ytm-radio--truncate
                (ytm-radio--track-title track)
                text-width)
               'bold)
              (when-let* ((artist (map-elt track :artist)))
                (ytm-radio--insert-centered-now-playing-line
                 (ytm-radio--truncate artist text-width)
                 'shadow))
              (when-let* ((time-label (ytm-radio--playback-time-label track)))
                (ytm-radio--insert-centered-now-playing-line
                 time-label
                 'shadow))
              (insert ytm-radio--now-playing-thin-padding)
              (ytm-radio--insert-now-playing-controls)
              (insert "\n")
              (insert ytm-radio--now-playing-thin-padding))
          (insert "No track\n"))))
    (when (and (frame-live-p ytm-radio--frame)
               (not ytm-radio--inhibit-frame-fit))
      (ytm-radio--fit-frame ytm-radio--frame buffer)
      (ytm-radio--position-frame ytm-radio--frame))))

(defun ytm-radio--show-regular-buffer (buffer)
  "Show BUFFER in a regular Emacs window."
  (pop-to-buffer buffer))

(defun ytm-radio--delete-frame ()
  "Delete the now-playing child frame, if any."
  (when (frame-live-p ytm-radio--frame)
    (let ((parent (frame-parent ytm-radio--frame)))
      (delete-frame ytm-radio--frame)
      (when (frame-live-p parent)
        (select-frame-set-input-focus parent))))
  (setq ytm-radio--frame nil))

(defun ytm-radio--buffer-image (buffer)
  "Return the first image displayed in BUFFER, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let (image)
        (while (and (not image) (not (eobp)))
          (when-let* ((display (get-text-property (point) 'display))
                      ((eq (car-safe display) 'image)))
            (setq image display))
          (goto-char (or (next-single-property-change (point) 'display)
                         (point-max))))
        image))))

(defun ytm-radio--now-playing-line-count (buffer)
  "Return BUFFER's line count."
  (with-current-buffer buffer
    (line-number-at-pos (point-max))))

(defun ytm-radio--now-playing-frame-height (frame buffer image)
  "Return FRAME height needed for BUFFER containing IMAGE."
  (let ((window (frame-root-window frame)))
    (or (with-current-buffer buffer
          (when-let* ((size (ignore-errors
                              (window-text-pixel-size
                               window (point-min) (point-max) nil nil))))
            (+ (ceiling (cdr size))
               (frame-char-height frame))))
        (let ((dimensions (image-size image t frame))
              (lines (ytm-radio--now-playing-line-count buffer)))
          (+ (ceiling (cdr dimensions))
             (* (max 0 (1- lines))
                (frame-char-height frame)))))))

(defun ytm-radio--now-playing-debug-data ()
  "Return live geometry data for the now-playing child frame."
  (unless (frame-live-p ytm-radio--frame)
    (user-error "No live ytm-radio child frame"))
  (let* ((frame ytm-radio--frame)
         (window (frame-root-window frame))
         (buffer (window-buffer window))
         (image (ytm-radio--buffer-image buffer))
         (inside (window-inside-pixel-edges window))
         (window-edges (window-pixel-edges window))
         (image-size (and image
                          (ignore-errors (image-size image t frame))))
         first-line-size)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (setq first-line-size
              (ignore-errors
                (window-text-pixel-size
                 window (point-min) (line-end-position) t nil)))))
    `((frame-pixel-width . ,(frame-pixel-width frame))
      (frame-inner-width . ,(frame-inner-width frame))
      (frame-text-width . ,(frame-text-width frame))
      (frame-char-width . ,(frame-char-width frame))
      (cover-left-padding-columns . ,ytm-radio--cover-left-padding-columns)
      (window-pixel-width . ,(window-pixel-width window))
      (window-body-width-px . ,(window-body-width window t))
      (window-body-width-cols . ,(window-body-width window))
      (window-pixel-edges . ,window-edges)
      (window-inside-pixel-edges . ,inside)
      (window-inside-width . ,(- (nth 2 inside) (nth 0 inside)))
      (image-size . ,image-size)
      (first-line-text-pixel-size . ,first-line-size)
      (right-gap-from-first-line . ,(and first-line-size
                                         (- (- (nth 2 inside) (nth 0 inside))
                                            (car first-line-size))))
      (right-gap-from-image . ,(and image-size
                                    (- (- (nth 2 inside) (nth 0 inside))
                                       (car image-size))))
      (truncate-lines . ,truncate-lines)
      (overflow-newline-into-fringe . ,overflow-newline-into-fringe)
      (fringes . ,(window-fringes window))
      (margins . ,(window-margins window))
      (scroll-bars . ,(window-scroll-bars window))
      (frame-left-fringe . ,(frame-parameter frame 'left-fringe))
      (frame-right-fringe . ,(frame-parameter frame 'right-fringe))
      (frame-scroll-bar-width . ,(frame-parameter frame 'scroll-bar-width))
      (frame-internal-border-width
       . ,(frame-parameter frame 'internal-border-width))
      (frame-child-frame-border-width
       . ,(frame-parameter frame 'child-frame-border-width)))))

(defun ytm-radio--fit-frame (frame buffer)
  "Size FRAME to fit BUFFER's image and text."
  (let ((frame-resize-pixelwise t))
    (if-let* ((image (ytm-radio--buffer-image buffer)))
        (let* ((image-size (image-size image t frame))
               (columns (ytm-radio--now-playing-layout-columns-for-cover
                         (car image-size)
                         frame)))
          (set-frame-width frame columns)
          (set-frame-height
           frame
           (ytm-radio--now-playing-frame-height frame buffer image)
           nil
           t))
      (make-frame-visible frame)
      (fit-frame-to-buffer frame)
      (set-frame-width frame (max ytm-radio-child-frame-width
                                  (+ 2 (frame-width frame)))))))

(defun ytm-radio--position-frame (frame)
  "Position child FRAME at the lower right of its parent."
  (when-let* ((parent (frame-parent frame)))
    (let* ((bottom-window (car (window-at-side-list parent 'bottom)))
           (mode-line-height (if bottom-window
                                 (window-mode-line-height bottom-window)
                               0))
           (content-bottom (- (frame-pixel-height parent)
                              (window-pixel-height (minibuffer-window parent))
                              mode-line-height))
           (x-margin (* 2 (frame-char-width parent)))
           (y-margin (frame-char-height parent)))
      (set-frame-position
       frame
       (max 0 (- (frame-pixel-width parent)
                 (frame-pixel-width frame)
                 x-margin))
       (max 0 (- content-bottom
                 (frame-pixel-height frame)
                 y-margin))))))

(defun ytm-radio--ensure-frame (buffer)
  "Return a child frame showing the now-playing BUFFER."
  (unless (frame-live-p ytm-radio--frame)
    (let* ((parent (selected-frame))
           (frame-resize-pixelwise t)
           (frame (make-frame
                   `((parent-frame . ,parent)
                     (minibuffer . nil)
                     (undecorated . t)
                     (skip-taskbar . t)
                     (no-other-frame . t)
                     (unsplittable . t)
                     (left-fringe . 0)
                     (right-fringe . 0)
                     (vertical-scroll-bars . nil)
                     (horizontal-scroll-bars . nil)
                     (scroll-bar-width . 0)
                     (scroll-bar-height . 0)
                     (right-divider-width . 0)
                     (bottom-divider-width . 0)
                     (menu-bar-lines . 0)
                     (tool-bar-lines . 0)
                     (tab-bar-lines . 0)
                     (internal-border-width . 0)
                     (child-frame-border-width . ,ytm-radio--frame-border-width)
                     (visibility . nil)))))
      (set-face-background 'child-frame-border
                           (or (face-foreground 'shadow nil t) "gray50")
                           frame)
      (setq ytm-radio--frame frame)))
  (let ((window (frame-root-window ytm-radio--frame)))
    (set-window-buffer window buffer)
    (set-window-dedicated-p window t)
    (set-window-fringes window 0 0 nil t)
    (set-window-margins window 0 0)
    (set-window-scroll-bars window 0 nil 0 nil t))
  (ytm-radio--fit-frame ytm-radio--frame buffer)
  (ytm-radio--position-frame ytm-radio--frame)
  ytm-radio--frame)

(defun ytm-radio--show-child-frame (buffer &optional focus)
  "Show now-playing BUFFER in a child frame.
When FOCUS is non-nil, select the child frame."
  (let ((frame (ytm-radio--ensure-frame buffer)))
    (make-frame-visible frame)
    (when focus
      (select-frame-set-input-focus frame))
    frame))

(defun ytm-radio--reposition-on-resize (frame)
  "Re-pin the now-playing child frame when parent FRAME changes size."
  (when (and (frame-live-p ytm-radio--frame)
             (eq frame (frame-parent ytm-radio--frame)))
    (ytm-radio--position-frame ytm-radio--frame)))

(add-hook 'window-size-change-functions #'ytm-radio--reposition-on-resize)

(defun ytm-radio--show-buffer (buffer)
  "Show browser BUFFER in a regular Emacs window."
  (ytm-radio--show-regular-buffer buffer))

(defun ytm-radio--show-now-playing (&optional focus)
  "Show the now-playing view using `ytm-radio-display-style'.
When FOCUS is non-nil, focus the now-playing child frame."
  (let ((buffer (ytm-radio--now-playing-buffer)))
    (ytm-radio--render-now-playing)
    (if (and (eq ytm-radio-display-style 'child-frame)
             (display-graphic-p))
        (ytm-radio--show-child-frame buffer focus)
      (ytm-radio--show-regular-buffer buffer))))

;;; Commands

;;;###autoload
(defun ytm-radio-auth-import (source output)
  "Import YouTube Music authentication from SOURCE into OUTPUT.
SOURCE is a login source such as \"chrome\", \"firefox\", \"safari\",
or \"dia\"."
  (interactive
   (list
    (completing-read "Login source: "
                     (ytm-radio--auth-import-candidates)
                     nil nil nil nil ytm-radio-helper-browser)
    (read-file-name "Auth file: "
                    (file-name-directory ytm-radio-helper-auth-file)
                    ytm-radio-helper-auth-file)))
  (if (ytm-radio--dia-auth-source-p source)
      (ytm-radio-auth-import-dia output)
    (ytm-radio-auth-import-browser source output)))

;;;###autoload
(defun ytm-radio-auth-import-dia (output)
  "Import YouTube Music authentication from Dia into OUTPUT."
  (interactive
   (list
    (read-file-name "Auth file: "
                    (file-name-directory ytm-radio-helper-auth-file)
                    ytm-radio-helper-auth-file)))
  (condition-case error
      (ytm-radio--helper-envelope-data
       (ytm-radio--call-helper
        (ytm-radio--helper-import-dia-arguments output)))
    (user-error
     (let ((message (error-message-string error)))
       (if (and (string-match-p "quit Dia and run import again" message)
                (yes-or-no-p
                 "Dia must be restarted once for login import.  Restart Dia now? "))
             (ytm-radio--helper-envelope-data
              (ytm-radio--call-helper
               (ytm-radio--helper-import-dia-arguments output t)))
         (signal (car error) (cdr error))))))
  (setq ytm-radio-helper-auth-file (expand-file-name output))
  (message "YouTube Music Dia session imported"))

;;;###autoload
(defun ytm-radio-auth-import-browser (browser output)
  "Import YouTube Music authentication from BROWSER into OUTPUT."
  (interactive
   (list
    (completing-read "Browser specification: "
                     ytm-radio-helper-browser-candidates
                     nil nil nil nil ytm-radio-helper-browser)
    (read-file-name "Auth file: "
                    (file-name-directory ytm-radio-helper-auth-file)
                    ytm-radio-helper-auth-file)))
  (ytm-radio--helper-envelope-data
   (ytm-radio--call-helper
    (ytm-radio--helper-import-browser-arguments browser output)))
  (setq ytm-radio-helper-auth-file (expand-file-name output))
  (message "YouTube Music browser session imported"))

;;;###autoload
(defun ytm-radio-auth-import-headers (input output)
  "Import YouTube Music authentication from browser request headers.
INPUT is a text file containing copied request headers.  OUTPUT is the
helper auth JSON file."
  (interactive
   (list
    (read-file-name "Headers file: " nil nil t)
    (read-file-name "Auth file: "
                    (file-name-directory ytm-radio-helper-auth-file)
                    ytm-radio-helper-auth-file)))
  (ytm-radio--helper-envelope-data
   (ytm-radio--call-helper
    (ytm-radio--helper-import-headers-arguments input output)))
  (setq ytm-radio-helper-auth-file (expand-file-name output))
  (message "YouTube Music browser headers imported"))

;;;###autoload
(defun ytm-radio ()
  "Open the ytm-radio YouTube Music browser."
  (interactive)
  (ytm-radio--ensure-loaded)
  (let ((buffer (ytm-radio--buffer)))
    (ytm-radio--render)
    (ytm-radio--show-buffer buffer)))

;;;###autoload
(defun ytm-radio-now-playing ()
  "Show the now-playing cover view."
  (interactive)
  (ytm-radio--ensure-loaded)
  (ytm-radio--show-now-playing t))

;;;###autoload
(defun ytm-radio-debug-now-playing-frame ()
  "Copy now-playing child-frame geometry diagnostics to the kill ring."
  (interactive)
  (let ((text (prin1-to-string (ytm-radio--now-playing-debug-data))))
    (kill-new text)
    (message "ytm-radio child-frame diagnostics copied: %s" text)))

;;;###autoload
(defun ytm-radio-add-url (url)
  "Add URL as a source and play its first track."
  (interactive (list (read-string "YouTube or YouTube Music URL: ")))
  (ytm-radio--ensure-loaded)
  (let ((source (ytm-radio--fetch-source url)))
    (unless (map-elt source :tracks)
      (user-error "No playable tracks found"))
    (ytm-radio--put-source source)
    (ytm-radio--save)
    (message "Added %s (%d tracks)"
             (ytm-radio--source-display-title source)
             (length (map-elt source :tracks)))
    (ytm-radio--play-track (car (map-elt source :tracks)))))

;;;###autoload
(defun ytm-radio-import-ytmusic-library ()
  "Import YouTube Music library sources through the Rust helper."
  (interactive)
  (ytm-radio--import-helper-target "library" "library"))

;;;###autoload
(defun ytm-radio-import-ytmusic-home ()
  "Import YouTube Music home recommendations through the Rust helper."
  (interactive)
  (ytm-radio--import-helper-target "home" "home recommendations"))

;;;###autoload
(defun ytm-radio-import-ytmusic-liked ()
  "Import YouTube Music liked songs through the Rust helper."
  (interactive)
  (ytm-radio--import-helper-target "liked" "liked songs"))

;;;###autoload
(defun ytm-radio-play-track ()
  "Select and play a known track."
  (interactive)
  (ytm-radio--ensure-loaded)
  (let ((choices (mapcar (lambda (track)
                           (cons (ytm-radio--track-label track) track))
                         (ytm-radio--all-tracks))))
    (unless choices
      (user-error "No tracks; add a URL first"))
    (ytm-radio--play-track
     (cdr (assoc (completing-read "Track: " choices nil t) choices)))))

;;;###autoload
(defun ytm-radio-play-source ()
  "Select a source and play its first track."
  (interactive)
  (ytm-radio--ensure-loaded)
  (let ((choices (mapcar (lambda (source)
                           (cons (ytm-radio--source-display-title source) source))
                         (map-values (ytm-radio--sources)))))
    (unless choices
      (user-error "No sources; add a URL first"))
    (let* ((source (cdr (assoc (completing-read "Source: " choices nil t)
                               choices))))
      (ytm-radio--play-source-object source))))

;;;###autoload
(defun ytm-radio-toggle-pause ()
  "Toggle playback pause, or resume the last known track."
  (interactive)
  (ytm-radio--ensure-loaded)
  (cond ((process-live-p (map-elt ytm-radio--player :process))
         (ytm-radio--mpv-send (list "cycle" "pause")))
        ((ytm-radio--current-track)
         (ytm-radio--play-track (ytm-radio--current-track)))
        (t
         (user-error "Nothing to play"))))

;;;###autoload
(defun ytm-radio-stop ()
  "Stop playback."
  (interactive)
  (ytm-radio--stop-process)
  (ytm-radio--render)
  (message "Stopped"))

;;;###autoload
(defun ytm-radio-next ()
  "Play the next track in catalog order."
  (interactive)
  (if-let* ((track (ytm-radio--current-track))
            (next (ytm-radio--next-track track)))
      (ytm-radio--play-track next)
    (user-error "No next track")))

;;;###autoload
(defun ytm-radio-previous ()
  "Play the previous track in catalog order."
  (interactive)
  (if-let* ((track (ytm-radio--current-track))
            (previous (ytm-radio--previous-track track)))
      (ytm-radio--play-track previous)
    (user-error "No previous track")))

;;;###autoload
(defun ytm-radio-share ()
  "Copy the current track URL for sharing."
  (interactive)
  (if-let* ((track (ytm-radio--current-track))
            (url (map-elt track :url)))
      (progn
        (kill-new url)
        (message "Copied track URL"))
    (user-error "No track URL to share")))

;;;###autoload
(defun ytm-radio-seek-forward (seconds)
  "Seek forward SECONDS seconds, defaulting to five."
  (interactive "P")
  (unless (process-live-p (map-elt ytm-radio--player :ipc-process))
    (user-error "Not playing"))
  (let ((amount (cond ((numberp seconds) seconds)
                      (seconds (* 60 (/ (prefix-numeric-value seconds) 4)))
                      (t 5))))
    (ytm-radio--mpv-send (list "seek" amount))))

;;;###autoload
(defun ytm-radio-seek-backward (seconds)
  "Seek backward SECONDS seconds, defaulting to five."
  (interactive "P")
  (unless seconds
    (setq seconds 5))
  (when (and seconds (not (numberp seconds)))
    (setq seconds (* 60 (/ (prefix-numeric-value seconds) 4))))
  (ytm-radio-seek-forward (- seconds)))

;;;###autoload
(defun ytm-radio-hide ()
  "Hide ytm-radio UI without stopping playback."
  (interactive)
  (ytm-radio--delete-frame)
  (dolist (buffer-name (list ytm-radio--library-buffer-name
                             ytm-radio--now-playing-buffer-name))
    (when-let* ((buffer (get-buffer buffer-name))
                (window (get-buffer-window buffer t)))
      (quit-window nil window))))

(provide 'ytm-radio)

;;; ytm-radio.el ends here
