;;; ytm-radio-test.el --- Tests for ytm-radio -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'map)
(require 'ytm-radio)

(defvar ytm-radio-test--data-directory
  (file-name-as-directory (make-temp-file "ytm-radio-test-data-" t))
  "Directory used for ytm-radio test runtime files.")

(setq ytm-radio-data-directory ytm-radio-test--data-directory
      ytm-radio-state-file
      (expand-file-name "state.eld" ytm-radio-test--data-directory)
      ytm-radio-helper-auth-file
      (expand-file-name "auth.json" ytm-radio-test--data-directory)
      ytm-radio-helper-install-directory
      (expand-file-name "bin/" ytm-radio-test--data-directory)
      ytm-radio-cover-cache-directory
      (expand-file-name "covers/" ytm-radio-test--data-directory))

(defun ytm-radio-test--detail-helper-source
    (browse-id kind title &rest fields)
  "Return a raw helper detail source for BROWSE-ID, KIND, and TITLE.
FIELDS are appended as extra raw helper fields."
  (append `((id . ,(format "ytm:browse:%s:header" browse-id))
            (kind . ,kind)
            (title . ,title)
            (url . ,(format "https://music.youtube.com/browse/%s" browse-id))
            (items . nil))
          fields))

(defun ytm-radio-test--detail-helper-data
    (browse-id kind title &rest fields)
  "Return raw helper detail mutation data for BROWSE-ID, KIND, and TITLE.
FIELDS are included on both the top-level mutation output and source."
  (let ((source (apply #'ytm-radio-test--detail-helper-source
                       browse-id kind title fields)))
    (append `((browse-id . ,browse-id)
              (changed . t)
              (sources . (,source)))
            fields)))

(ert-deftest ytm-radio-source-from-json-normalizes-music-playlist ()
  "Normalize YouTube Music playlist JSON into source and tracks."
  (let* ((json (json-parse-string
                "{\"id\":\"PL1\",\"title\":\"Road songs\",\"entries\":[{\"id\":\"a1\",\"title\":\"First\",\"duration\":123,\"url\":\"https://music.youtube.com/watch?v=a1\",\"artist\":\"Artist\",\"album\":\"Album\",\"thumbnails\":[{\"url\":\"small.jpg\"},{\"url\":\"large.jpg\"}]}]}"
                :object-type 'alist
                :array-type 'list))
         (source (ytm-radio--source-from-json
                  json
                  "https://music.youtube.com/playlist?list=PL1"))
         (track (car (map-elt source :tracks))))
    (should (equal (map-elt source :id) "PL1"))
    (should (eq (map-elt source :kind) 'youtube-music-playlist))
    (should (equal (map-elt track :title) "First"))
    (should (equal (map-elt track :artist) "Artist"))
    (should (equal (map-elt track :album) "Album"))
    (should (equal (map-elt track :thumbnail-url) "large.jpg"))
    (should (equal (map-elt track :source-id) "PL1"))))

(ert-deftest ytm-radio-source-from-json-builds-music-watch-url ()
  "Build a YouTube Music watch URL when flat entries only include IDs."
  (let* ((json (json-parse-string
                "{\"id\":\"PL2\",\"title\":\"Flat\",\"entries\":[{\"id\":\"b2\",\"title\":\"Second\",\"url\":\"b2\"}]}"
                :object-type 'alist
                :array-type 'list))
         (source (ytm-radio--source-from-json
                  json
                  "https://music.youtube.com/playlist?list=PL2"))
         (track (car (map-elt source :tracks))))
    (should (equal (map-elt track :url)
                   "https://music.youtube.com/watch?v=b2"))))

(ert-deftest ytm-radio-source-from-json-normalizes-single-track ()
  "Normalize a single video JSON object into a one-track source."
  (let* ((json (json-parse-string
                "{\"id\":\"c3\",\"title\":\"Single\",\"duration\":42,\"webpage_url\":\"https://www.youtube.com/watch?v=c3\"}"
                :object-type 'alist
                :array-type 'list))
         (source (ytm-radio--source-from-json
                  json
                  "https://www.youtube.com/watch?v=c3")))
    (should (eq (map-elt source :kind) 'youtube-track))
    (should (= (length (map-elt source :tracks)) 1))
    (should (equal (map-elt (car (map-elt source :tracks)) :url)
                   "https://www.youtube.com/watch?v=c3"))))

(ert-deftest ytm-radio-source-from-json-detects-channel-url ()
  "Classify handle URLs with entries as YouTube channels."
  (let* ((json (json-parse-string
                "{\"channel_id\":\"UC1\",\"title\":\"Videos\",\"entries\":[{\"id\":\"d4\",\"title\":\"Fourth\"}]}"
                :object-type 'alist
                :array-type 'list))
         (source (ytm-radio--source-from-json
                  json
                  "https://www.youtube.com/@example/videos")))
    (should (eq (map-elt source :kind) 'youtube-channel))
    (should (equal (map-elt source :id) "UC1"))))

(ert-deftest ytm-radio-state-file-requires-current-version ()
  "Reject durable state files that do not match the current state version."
  (let ((ytm-radio-state-file (make-temp-file "ytm-radio-state-")))
    (unwind-protect
        (progn
          (with-temp-file ytm-radio-state-file
            (prin1 (list (cons :version 0)
                         (cons :sources nil)
                         (cons :last-track-id nil))
                   (current-buffer)))
          (should-error (ytm-radio--read-state-file) :type 'user-error))
      (when (file-exists-p ytm-radio-state-file)
        (delete-file ytm-radio-state-file)))))

(ert-deftest ytm-radio-state-file-disables-read-eval ()
  "Read durable state with `read-eval' disabled and restored afterward."
  (let ((ytm-radio-state-file (make-temp-file "ytm-radio-state-"))
        (read-eval t))
    (unwind-protect
        (progn
          (with-temp-file ytm-radio-state-file
            (insert "#.(error \"read-eval executed\")"))
          (should-error (ytm-radio--read-state-file))
          (should read-eval))
      (when (file-exists-p ytm-radio-state-file)
        (delete-file ytm-radio-state-file)))))

(ert-deftest ytm-radio-state-file-handles-unbound-read-eval ()
  "Read durable state without requiring `read-eval' to be globally bound."
  (let* ((ytm-radio-state-file (make-temp-file "ytm-radio-state-"))
         (read-eval-symbol (intern "read-eval"))
         (read-eval-bound (boundp read-eval-symbol))
         (old-read-eval (and read-eval-bound
                             (symbol-value read-eval-symbol))))
    (unwind-protect
        (progn
          (makunbound read-eval-symbol)
          (with-temp-file ytm-radio-state-file
            (prin1 (list (cons :version ytm-radio--state-version)
                         (cons :sources nil)
                         (cons :last-track-id nil))
                   (current-buffer)))
          (should (ytm-radio--read-state-file))
          (should-not (boundp read-eval-symbol)))
      (if read-eval-bound
          (set read-eval-symbol old-read-eval)
        (when (boundp read-eval-symbol)
          (makunbound read-eval-symbol)))
      (when (file-exists-p ytm-radio-state-file)
        (delete-file ytm-radio-state-file)))))

(ert-deftest ytm-radio-state-file-persists-home-continuation ()
  "Persist Home continuation tokens across sessions."
  (let ((ytm-radio-state-file (make-temp-file "ytm-radio-state-"))
        (ytm-radio--state
         (ytm-radio--make-state
          :home-continuation "next-page"
          :home-continuation-known t)))
    (unwind-protect
        (progn
          (ytm-radio--save)
          (setq ytm-radio--state (ytm-radio--make-state))
          (ytm-radio--load)
          (should (equal (ytm-radio--home-continuation) "next-page"))
          (should (equal (map-elt ytm-radio--state :home-continuation)
                         "next-page"))
          (should (map-elt ytm-radio--state :home-continuation-known)))
      (when (file-exists-p ytm-radio-state-file)
        (delete-file ytm-radio-state-file)))))

(ert-deftest ytm-radio-state-file-treats-missing-home-continuation-as-unknown ()
  "Treat old state files without Home continuation as needing refresh."
  (let ((ytm-radio-state-file (make-temp-file "ytm-radio-state-"))
        (ytm-radio--state (ytm-radio--make-state)))
    (unwind-protect
        (progn
          (with-temp-file ytm-radio-state-file
            (prin1 (list (cons :version ytm-radio--state-version)
                         (cons :sources nil)
                         (cons :last-track-id nil))
                   (current-buffer)))
          (ytm-radio--load)
          (should-not (ytm-radio--home-continuation))
          (should-not (map-elt ytm-radio--state :home-continuation-known)))
      (when (file-exists-p ytm-radio-state-file)
        (delete-file ytm-radio-state-file)))))

(ert-deftest ytm-radio-add-url-imports-asynchronously ()
  "Play URLs through async yt-dlp import without storing them."
  (let* ((ytm-radio--loaded t)
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--add-url-process nil)
         (source (ytm-radio--make-source
                  :id "src"
                  :kind 'youtube-track
                  :title "Source"
                  :url "https://youtu.be/v1"
                  :tracks (list (ytm-radio--make-track
                                 :id "v1"
                                 :title "Song"
                                 :url "https://youtu.be/v1"))))
         imported-url
         import-success
         played-source
         saved)
    (cl-letf (((symbol-function 'ytm-radio--fetch-source-async)
               (lambda (url success _error-callback)
                 (setq imported-url url)
                 (setq import-success success)
                 'process))
              ((symbol-function 'ytm-radio--save)
               (lambda () (setq saved t)))
              ((symbol-function 'ytm-radio--play-source-object)
               (lambda (played)
                 (setq played-source played)))
              ((symbol-function 'process-live-p) (lambda (_process) nil))
              ((symbol-function 'message) #'ignore))
      (ytm-radio-add-url "https://youtu.be/v1")
      (should (equal imported-url "https://youtu.be/v1"))
      (should (eq ytm-radio--add-url-process 'process))
      (funcall import-success source)
      (should (eq played-source source))
      (should-not (ytm-radio--source "src"))
      (should-not saved)
      (should-not ytm-radio--add-url-process))))

(ert-deftest ytm-radio-yt-dlp-arguments-include-proxy ()
  "Build yt-dlp arguments with the first-class proxy setting."
  (let ((ytm-radio-yt-dlp-extra-args '("--cookies-from-browser" "chrome"))
        (ytm-radio-mpv-ytdl-format "bestaudio/best")
        (ytm-radio-proxy-url "socks5h://127.0.0.1:7890"))
    (should (equal (ytm-radio--yt-dlp-metadata-arguments "url")
                   '("--cookies-from-browser"
                     "chrome"
                     "--proxy"
                     "socks5h://127.0.0.1:7890"
                     "--flat-playlist"
                     "--dump-single-json"
                     "url")))
    (should (equal (ytm-radio--stream-resolve-arguments "url")
                   '("--cookies-from-browser"
                     "chrome"
                     "--proxy"
                     "socks5h://127.0.0.1:7890"
                     "--no-playlist"
                     "-f"
                     "bestaudio/best"
                     "-g"
                     "url")))))

(ert-deftest ytm-radio-mpv-arguments-include-ytdl-raw-options ()
  "Build mpv arguments with raw ytdl options."
  (let ((ytm-radio-mpv-extra-args '("--really-quiet"))
        (ytm-radio-mpv-network-cache-args '("--cache=yes"
                                            "--cache-pause=no"
                                            "--demuxer-readahead-secs=60"
                                            "--demuxer-max-bytes=256MiB"))
        (ytm-radio-mpv-ytdl-format "bestaudio/best")
        (ytm-radio-proxy-url nil)
        (ytm-radio-ytdl-raw-options '("cookies-from-browser=chrome"
                                      "proxy=http://127.0.0.1:8888")))
    (should (equal (ytm-radio--mpv-arguments "sock" "url")
                   '("--cache=yes"
                     "--cache-pause=no"
                     "--demuxer-readahead-secs=60"
                     "--demuxer-max-bytes=256MiB"
                     "--ytdl-format=bestaudio/best"
                     "--pause=no"
                     "--really-quiet"
                     "--ytdl-raw-options=cookies-from-browser=chrome,proxy=http://127.0.0.1:8888"
                     "--no-video"
                     "--input-ipc-server=sock"
                     "url")))))

(ert-deftest ytm-radio-mpv-arguments-include-first-class-proxy ()
  "Build mpv arguments with the first-class proxy setting."
  (let ((ytm-radio-mpv-extra-args '("--really-quiet"))
        (ytm-radio-mpv-network-cache-args nil)
        (ytm-radio-mpv-ytdl-format "bestaudio/best")
        (ytm-radio-ytdl-raw-options '("cookies-from-browser=chrome"))
        (ytm-radio-proxy-url "http://127.0.0.1:8888"))
    (should (equal (ytm-radio--mpv-arguments "sock" "url")
                   '("--ytdl-format=bestaudio/best"
                     "--http-proxy=http://127.0.0.1:8888"
                     "--stream-lavf-o-append=http_proxy=http://127.0.0.1:8888"
                     "--pause=no"
                     "--really-quiet"
                     "--ytdl-raw-options=cookies-from-browser=chrome,proxy=http://127.0.0.1:8888"
                     "--no-video"
                     "--input-ipc-server=sock"
                     "url")))))

(ert-deftest ytm-radio-cover-download-uses-first-class-http-proxy ()
  "Download covers through the first-class HTTP proxy setting."
  (let* ((directory (make-temp-file "ytm-radio-cover-proxy-" t))
         (ytm-radio-cover-cache-directory directory)
         (ytm-radio--cover-downloads (make-hash-table :test #'equal))
         (ytm-radio-proxy-url "http://127.0.0.1:7890")
         captured-proxy-services)
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve)
                   (lambda (_url _callback &rest _arguments)
                     (setq captured-proxy-services url-proxy-services)
                     'process)))
          (ytm-radio--cache-cover "https://example.com/cover.jpg" #'ignore)
          (should (equal captured-proxy-services
                         '(("http" . "127.0.0.1:7890")
                           ("https" . "127.0.0.1:7890")))))
      (delete-directory directory t))))

(ert-deftest ytm-radio-mpv-extra-args-can-override-cache-defaults ()
  "Place user mpv args after default mpv playback args."
  (let ((ytm-radio-mpv-network-cache-args '("--cache=yes"
                                            "--demuxer-readahead-secs=60"))
        (ytm-radio-mpv-ytdl-format "bestaudio/best")
        (ytm-radio-mpv-extra-args '("--demuxer-readahead-secs=5"
                                    "--ytdl-format=worstaudio/best"))
        (ytm-radio-proxy-url nil)
        (ytm-radio-ytdl-raw-options nil))
    (should (equal (seq-take (ytm-radio--mpv-arguments "sock" "url") 6)
                   '("--cache=yes"
                     "--demuxer-readahead-secs=60"
                     "--ytdl-format=bestaudio/best"
                     "--pause=no"
                     "--demuxer-readahead-secs=5"
                     "--ytdl-format=worstaudio/best")))))

(ert-deftest ytm-radio-mpv-ytdl-format-can-use-mpv-default ()
  "Omit the ytdl format argument when configured nil."
  (let ((ytm-radio-mpv-network-cache-args nil)
        (ytm-radio-mpv-ytdl-format nil)
        (ytm-radio-mpv-extra-args nil)
        (ytm-radio-proxy-url nil)
        (ytm-radio-ytdl-raw-options nil))
    (should-not
     (member "--ytdl-format=bestaudio/best"
             (ytm-radio--mpv-arguments "sock" "url")))))

(ert-deftest ytm-radio-playback-url-uses-valid-stream-cache ()
  "Use cached direct stream URLs until they are close to expiry."
  (let* ((ytm-radio--stream-url-cache (make-hash-table :test #'equal))
         (ytm-radio-proxy-url nil)
         (track (ytm-radio--make-track
                 :id "v1"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=v1"))
         (direct-url "https://rr.example/videoplayback?expire=9999999999"))
    (ytm-radio--cache-stream-url track direct-url)
    (should (equal (ytm-radio--playback-url-choice track)
                   (list direct-url t)))
    (puthash "v1"
             (list (cons 'url "https://rr.example/expired")
                   (cons 'expires 1))
             ytm-radio--stream-url-cache)
    (should (equal (ytm-radio--playback-url-choice track)
                   (list "https://music.youtube.com/watch?v=v1" nil)))))

(ert-deftest ytm-radio-socks-proxy-skips-direct-stream-cache ()
  "Do not use cached direct stream URLs when only SOCKS proxy is configured."
  (let* ((ytm-radio--stream-url-cache (make-hash-table :test #'equal))
         (ytm-radio-proxy-url "socks5h://127.0.0.1:7890")
         (track (ytm-radio--make-track
                 :id "v1"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=v1")))
    (ytm-radio--cache-stream-url
     track
     "https://rr.example/videoplayback?expire=9999999999")
    (should (equal (ytm-radio--playback-url-choice track)
                   (list "https://music.youtube.com/watch?v=v1" nil)))))

(ert-deftest ytm-radio-play-track-prefetches-next-track ()
  "Schedule the next track for background stream prefetch after playback starts."
  (let* ((track-a (ytm-radio--make-track
                   :id "a"
                   :title "A"
                   :url "https://music.youtube.com/watch?v=a"))
         (track-b (ytm-radio--make-track
                   :id "b"
                   :title "B"
                   :url "https://music.youtube.com/watch?v=b"))
         (source (ytm-radio--make-source
                  :id "s"
                  :kind 'youtube-music-library
                  :title "S"
                  :tracks (list track-a track-b)))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons "s" source))))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio-mpv-network-cache-args nil)
         (ytm-radio-mpv-extra-args nil)
         (ytm-radio-proxy-url nil)
         (ytm-radio-ytdl-raw-options nil)
         process
         scheduled)
    (unwind-protect
        (cl-letf (((symbol-function 'ytm-radio--ensure-program) #'ignore)
                  ((symbol-function 'ytm-radio--stop-process) #'ignore)
                  ((symbol-function 'ytm-radio--mpv-connect) #'ignore)
                  ((symbol-function 'ytm-radio--render) #'ignore)
                  ((symbol-function 'ytm-radio--show-now-playing) #'ignore)
                  ((symbol-function 'ytm-radio--save) #'ignore)
                  ((symbol-function 'ytm-radio--refresh-track-status) #'ignore)
                  ((symbol-function 'ytm-radio--schedule-stream-prefetch)
                   (lambda (tracks) (setq scheduled tracks)))
                  ((symbol-function 'start-process)
                   (lambda (name buffer _program &rest _args)
                     (setq process
                           (make-process
                            :name name
                            :buffer buffer
                            :command '("sleep" "2")
                            :noquery t)))))
          (ytm-radio--play-track track-a)
          (should (equal scheduled (list track-b))))
      (when (processp process)
        (set-process-sentinel process nil)
        (when (process-live-p process)
          (delete-process process))))))

(ert-deftest ytm-radio-play-track-restarts-current-track-in-place ()
  "Restart the current track with mpv IPC instead of replacing mpv."
  (let* ((track-a (ytm-radio--make-track
                   :id "a"
                   :title "A"
                   :url "https://music.youtube.com/watch?v=a"))
         (track-b (ytm-radio--make-track
                   :id "b"
                   :title "B"
                   :url "https://music.youtube.com/watch?v=b"))
         (source (ytm-radio--make-source
                  :id "s"
                  :kind 'youtube-music-library
                  :title "S"
                  :tracks (list track-a track-b)))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons "s" source))
           :last-track-id "a"))
         (ytm-radio--player
          (ytm-radio--make-player
           :status 'paused
           :current-track track-a
           :process 'mpv-process
           :ipc-process 'mpv-ipc
           :position 42
           :duration 180))
         commands
         scheduled)
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (process) (memq process '(mpv-process mpv-ipc))))
              ((symbol-function 'ytm-radio--ensure-program) #'ignore)
              ((symbol-function 'ytm-radio--stop-process)
               (lambda () (error "should not stop mpv")))
              ((symbol-function 'start-process)
               (lambda (&rest _args) (error "should not start mpv")))
              ((symbol-function 'ytm-radio--mpv-send)
               (lambda (command) (push command commands)))
              ((symbol-function 'ytm-radio--render) #'ignore)
              ((symbol-function 'ytm-radio--show-now-playing) #'ignore)
              ((symbol-function 'ytm-radio--refresh-track-status) #'ignore)
              ((symbol-function 'ytm-radio--schedule-stream-prefetch)
               (lambda (tracks) (setq scheduled tracks))))
      (ytm-radio--play-track track-a)
      (should (member '("seek" 0 "absolute") commands))
      (should (member '("set_property" "pause" :json-false) commands))
      (should (eq (map-elt ytm-radio--player :status) 'playing))
      (should (= (map-elt ytm-radio--player :position) 0))
      (should (= (map-elt ytm-radio--player :duration) 180))
      (should (equal scheduled (list track-b))))))

(ert-deftest ytm-radio-play-track-loads-next-track-in-current-mpv ()
  "Load a different track into the current mpv process when IPC is ready."
  (let* ((track-a (ytm-radio--make-track
                   :id "a"
                   :title "A"
                   :url "https://music.youtube.com/watch?v=a"))
         (track-b (ytm-radio--make-track
                   :id "b"
                   :title "B"
                   :duration 200
                   :url "https://music.youtube.com/watch?v=b"))
         (track-c (ytm-radio--make-track
                   :id "c"
                   :title "C"
                   :url "https://music.youtube.com/watch?v=c"))
         (source (ytm-radio--make-source
                  :id "s"
                  :kind 'youtube-music-library
                  :title "S"
                  :tracks (list track-a track-b track-c)))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons "s" source))
           :last-track-id "a"))
         (ytm-radio--player
          (ytm-radio--make-player
           :status 'playing
           :current-track track-a
           :process 'mpv-process
           :ipc-process 'mpv-ipc
           :position 42))
         commands
         scheduled)
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (process) (memq process '(mpv-process mpv-ipc))))
              ((symbol-function 'ytm-radio--ensure-program) #'ignore)
              ((symbol-function 'ytm-radio--stop-process)
               (lambda () (error "should not stop mpv")))
              ((symbol-function 'start-process)
               (lambda (&rest _args) (error "should not start mpv")))
              ((symbol-function 'ytm-radio--mpv-send)
               (lambda (command) (push command commands)))
              ((symbol-function 'ytm-radio--save) #'ignore)
              ((symbol-function 'ytm-radio--render) #'ignore)
              ((symbol-function 'ytm-radio--show-now-playing) #'ignore)
              ((symbol-function 'ytm-radio--refresh-track-status) #'ignore)
              ((symbol-function 'ytm-radio--schedule-stream-prefetch)
               (lambda (tracks) (setq scheduled tracks))))
      (ytm-radio--play-track track-b)
      (should (member '("loadfile"
                        "https://music.youtube.com/watch?v=b"
                        "replace")
                      commands))
      (should (member '("set_property" "pause" :json-false) commands))
      (should (equal (map-elt ytm-radio--player :current-track) track-b))
      (should (eq (map-elt ytm-radio--player :status) 'loading))
      (should (= (map-elt ytm-radio--player :duration) 200))
      (should (equal scheduled (list track-c))))))

(ert-deftest ytm-radio-mpv-error-retries-cached-stream-with-original-url ()
  "Recover from a bad cached stream URL by retrying the original URL once."
  (let* ((ytm-radio--stream-url-cache (make-hash-table :test #'equal))
         (track (ytm-radio--make-track
                 :id "v1"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=v1"))
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player
          (ytm-radio--make-player
           :status 'playing
           :current-track track
           :process 'mpv-process
           :ipc-process 'mpv-ipc
           :playback-url "https://rr.example/bad"
           :using-stream-cache t))
         commands)
    (puthash "v1"
             (list (cons 'url "https://rr.example/bad")
                   (cons 'expires 9999999999))
             ytm-radio--stream-url-cache)
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (process) (memq process '(mpv-process mpv-ipc))))
              ((symbol-function 'ytm-radio--mpv-send)
               (lambda (command) (push command commands)))
              ((symbol-function 'ytm-radio--render) #'ignore)
              ((symbol-function 'ytm-radio--show-now-playing) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio--mpv-event
       "end-file"
       '((reason . "error")
         (file_error . "unrecognized file format")))
      (should-not (gethash "v1" ytm-radio--stream-url-cache))
      (should (member '("loadfile"
                        "https://music.youtube.com/watch?v=v1"
                        "replace")
                      commands))
      (should (member '("set_property" "pause" :json-false) commands))
      (should (eq (map-elt ytm-radio--player :status) 'loading))
      (should-not (map-elt ytm-radio--player :using-stream-cache))
      (should (eq (map-elt ytm-radio--player :retry-stage) 'original)))))

(ert-deftest ytm-radio-mpv-error-retries-original-url-once ()
  "Retry a transient mpv playback error once for the original track URL."
  (let* ((track (ytm-radio--make-track
                 :id "v1"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=v1"))
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player
          (ytm-radio--make-player
           :status 'playing
           :current-track track
           :process 'mpv-process
           :ipc-process 'mpv-ipc
           :playback-url "https://music.youtube.com/watch?v=v1"
           :using-stream-cache nil))
         commands
         messages)
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (process) (memq process '(mpv-process mpv-ipc))))
              ((symbol-function 'ytm-radio--mpv-send)
               (lambda (command) (push command commands)))
              ((symbol-function 'ytm-radio--render) #'ignore)
              ((symbol-function 'ytm-radio--show-now-playing) #'ignore)
              ((symbol-function 'ytm-radio--render-now-playing-without-fit)
               #'ignore)
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (ytm-radio--mpv-event
       "end-file"
       '((reason . "error")
         (file_error . "no audio or video data played")))
      (should (member '("loadfile"
                        "https://music.youtube.com/watch?v=v1"
                        "replace")
                      commands))
      (should (eq (map-elt ytm-radio--player :status) 'loading))
      (should (eq (map-elt ytm-radio--player :retry-stage) 'final))
      (should (member "Playback failed; retrying" messages))
      (let ((command-count (length commands)))
        (ytm-radio--mpv-event
         "end-file"
         '((reason . "error")
           (file_error . "no audio or video data played")))
        (should (= (length commands) command-count)))
      (should (eq (map-elt ytm-radio--player :status) 'stopped))
      (should (member "Playback error: no audio or video data played"
                      messages)))))

(ert-deftest ytm-radio-mpv-error-restarts-when-ipc-closes-during-retry ()
  "Restart mpv when IPC closes while handling an error event."
  (let* ((track (ytm-radio--make-track
                 :id "v1"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=v1"))
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player
          (ytm-radio--make-player
           :status 'playing
           :current-track track
           :process 'mpv-process
           :ipc-process 'mpv-ipc
           :playback-url "https://music.youtube.com/watch?v=v1"
           :using-stream-cache nil))
         retried-track
         stopped-preserve)
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (process) (memq process '(mpv-process mpv-ipc))))
              ((symbol-function 'process-send-string)
               (lambda (&rest _args)
                 (error "Process ytm-radio-mpv-ipc no longer connected")))
              ((symbol-function 'ytm-radio--stop-process)
               (lambda (&optional preserve-retry-stage)
                 (setq stopped-preserve preserve-retry-stage)))
              ((symbol-function 'ytm-radio--play-track)
               (lambda (track &optional _preserve-retry-stage)
                 (setq retried-track track)))
              ((symbol-function 'message) #'ignore))
      (ytm-radio--mpv-event
       "end-file"
       '((reason . "error")
         (file_error . "no audio or video data played")))
      (should (equal retried-track track))
      (should stopped-preserve)
      (should (eq (map-elt ytm-radio--player :retry-stage) 'final))
      (should-not (map-elt ytm-radio--player :ipc-process)))))

(ert-deftest ytm-radio-mpv-sentinel-retries-cache-before-ipc ()
  "Recover when a cached stream fails before the mpv IPC connection is ready."
  (let* ((ytm-radio--stream-url-cache (make-hash-table :test #'equal))
         (track (ytm-radio--make-track
                 :id "v1"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=v1"))
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player
          (ytm-radio--make-player
           :status 'loading
           :current-track track
           :process 'mpv-process
           :playback-url "https://rr.example/bad"
           :using-stream-cache t))
         retried-track
         stopped)
    (puthash "v1"
             (list (cons 'url "https://rr.example/bad")
                   (cons 'expires 9999999999))
             ytm-radio--stream-url-cache)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) nil))
              ((symbol-function 'process-exit-status) (lambda (_process) 2))
              ((symbol-function 'ytm-radio--stop-process)
               (lambda (&optional _preserve-retry-stage) (setq stopped t)))
              ((symbol-function 'ytm-radio--play-track)
               (lambda (track &optional _preserve-retry-stage)
                 (setq retried-track track)))
              ((symbol-function 'message) #'ignore))
      (ytm-radio--mpv-sentinel 'mpv-process "exited")
      (should stopped)
      (should (equal retried-track track))
      (should-not (gethash "v1" ytm-radio--stream-url-cache)))))

(ert-deftest ytm-radio-mpv-sentinel-preserves-original-url-retry-before-ipc ()
  "Keep the one-shot retry marker when mpv exits before IPC is ready."
  (let* ((track (ytm-radio--make-track
                 :id "v1"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=v1"))
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player
          (ytm-radio--make-player
           :status 'loading
           :current-track track
           :process 'mpv-process
           :playback-url "https://music.youtube.com/watch?v=v1"
           :using-stream-cache nil))
         retried-track)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) nil))
              ((symbol-function 'process-exit-status) (lambda (_process) 2))
              ((symbol-function 'ytm-radio--play-track)
               (lambda (track &optional _preserve-retry-stage)
                 (setq retried-track track)))
              ((symbol-function 'message) #'ignore))
      (ytm-radio--mpv-sentinel 'mpv-process "exited")
      (should (equal retried-track track))
      (should (eq (map-elt ytm-radio--player :retry-stage) 'final)))))

(ert-deftest ytm-radio-render-explains-empty-catalog ()
  "Render an empty catalog with next-step guidance."
  (let ((ytm-radio--state (ytm-radio--make-state))
        (ytm-radio--player (ytm-radio--make-player))
        (ytm-radio--browser-view 'home))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (let ((header (substring-no-properties
                     (ytm-radio--browser-header-line))))
        (should (string-match-p "\\` YT[[:space:]]+Home" header))
        (should (string-match-p "Home[[:space:]]+Explore[[:space:]]+Library"
                                header))
        (should-not (string-match-p "ytm-radio" header)))
      (should-not (string-match-p "\\`Home[[:space:]]+Explore"
                                  (buffer-string)))
      (should-not (string-match-p "\\_<All\\_>" (buffer-string)))
      (should-not (string-match-p "\\`ytm-radio" (buffer-string)))
      (should-not (string-match-p "^No track$" (buffer-string)))
      (should-not (string-match-p "\nHome\n" (buffer-string)))
      (should (string-match-p
               "Add a URL, or import your YouTube Music library/home"
               (buffer-string)))
      (should (string-match-p
	               "YouTube Music login opens automatically when needed"
	               (buffer-string))))))

(ert-deftest ytm-radio-browser-header-omits-detail-context ()
  "Keep detail titles out of the header line."
  (let ((ytm-radio--browser-view
         (list (cons :kind 'detail)
               (cons :title "Album"))))
    (let ((header (substring-no-properties
                   (ytm-radio--browser-header-line))))
      (should (string-match-p "Home[[:space:]]+Explore[[:space:]]+Library"
                              header))
      (should-not (string-match-p "Album" header)))))

(ert-deftest ytm-radio-browser-header-highlights-detail-origin ()
  "Highlight the root view that opened a detail view."
  (let ((ytm-radio--browser-view
         (list (cons :kind 'detail)
               (cons :origin-view 'library)
               (cons :title "Album"))))
    (should (ytm-radio--browser-root-active-p 'library))
    (should-not (ytm-radio--browser-root-active-p 'home))
    (should-not (ytm-radio--browser-root-active-p 'explore))))

(ert-deftest ytm-radio-browser-header-highlights-search-page ()
  "Highlight Search as the current non-root page."
  (let* ((ytm-radio--browser-view
          (list (cons :kind 'search)
                (cons :query "chill girl")
                (cons :title "Search: chill girl")))
         (header (ytm-radio--browser-header-line))
         (start (string-match "Search: chill girl" header)))
    (should start)
    (should (eq (get-text-property start 'face header)
                'ytm-radio-header-active))
    (should-not (ytm-radio--browser-root-active-p 'home))
    (should-not (ytm-radio--browser-root-active-p 'explore))
    (should-not (ytm-radio--browser-root-active-p 'library))))

(ert-deftest ytm-radio-browser-header-highlights-queue-page ()
  "Highlight Queue as the current non-root page."
  (let* ((ytm-radio--browser-view 'queue)
         (header (ytm-radio--browser-header-line))
         (start (string-match "Queue" header)))
    (should start)
    (should (eq (get-text-property start 'face header)
                'ytm-radio-header-active))
    (should-not (ytm-radio--browser-root-active-p 'home))
    (should-not (ytm-radio--browser-root-active-p 'explore))
    (should-not (ytm-radio--browser-root-active-p 'library))))

(ert-deftest ytm-radio-open-uses-cached-home-without-refresh ()
  "Use cached Home sources on first browser open without refreshing."
  (let* ((stale-home (ytm-radio--make-source
                      :id "ytm:home:stale"
                      :kind 'youtube-music-home-section
                      :title "Stale Home"))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt stale-home :id) stale-home))
           :home-continuation nil
           :home-continuation-known t))
        (ytm-radio--player (ytm-radio--make-player))
        (ytm-radio--loaded t)
        (ytm-radio--browser-view 'home)
        (ytm-radio--initial-home-refreshed nil)
        (ytm-radio-helper-auth-file "/tmp/ytm-radio-auth.json")
        started)
    (cl-letf (((symbol-function 'file-readable-p)
               (lambda (file) (equal file "/tmp/ytm-radio-auth.json")))
              ((symbol-function 'ytm-radio--show-buffer)
               (lambda (_buffer) nil))
              ((symbol-function 'ytm-radio--start-home-load)
               (lambda (&optional append)
                 (setq started (if append 'append 'initial)))))
      (ytm-radio)
      (should-not started))))

(ert-deftest ytm-radio-open-refreshes-cached-home-with-unknown-continuation ()
  "Refresh old cached Home state when continuation was never persisted."
  (let* ((stale-home (ytm-radio--make-source
                      :id "ytm:home:stale"
                      :kind 'youtube-music-home-section
                      :title "Stale Home"))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt stale-home :id) stale-home))))
        (ytm-radio--player (ytm-radio--make-player))
        (ytm-radio--loaded t)
        (ytm-radio--browser-view 'home)
        (ytm-radio--initial-home-refreshed nil)
        (ytm-radio-helper-auth-file "/tmp/ytm-radio-auth.json")
        started)
    (cl-letf (((symbol-function 'file-readable-p)
               (lambda (file) (equal file "/tmp/ytm-radio-auth.json")))
              ((symbol-function 'ytm-radio--show-buffer)
               (lambda (_buffer) nil))
              ((symbol-function 'ytm-radio--start-home-load)
               (lambda (&optional append)
                 (setq started (if append 'append 'initial)))))
      (ytm-radio)
      (should (eq started 'initial)))))

(ert-deftest ytm-radio-opens-with-home-import-when-auth-exists-and-no-cache ()
  "Refresh Home on first browser open when account auth is available and uncached."
  (let ((ytm-radio--state (ytm-radio--make-state))
        (ytm-radio--player (ytm-radio--make-player))
        (ytm-radio--loaded t)
        (ytm-radio--browser-view 'home)
        (ytm-radio--initial-home-refreshed nil)
        (ytm-radio-helper-auth-file "/tmp/ytm-radio-auth.json")
        started)
    (cl-letf (((symbol-function 'file-readable-p)
               (lambda (file) (equal file "/tmp/ytm-radio-auth.json")))
              ((symbol-function 'ytm-radio--show-buffer)
               (lambda (_buffer) nil))
              ((symbol-function 'ytm-radio--start-home-load)
               (lambda (&optional append)
                 (setq started (if append 'append 'initial)))))
      (ytm-radio)
      (should (eq started 'initial)))))

(ert-deftest ytm-radio-opens-login-when-auth-is-missing-and-home-uncached ()
  "Start the login flow on first browser open when Home needs account auth."
  (let* ((directory (make-temp-file "ytm-radio-auth-" t))
         (auth-file (expand-file-name "auth.json" directory))
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--loaded t)
         (ytm-radio--browser-view 'home)
         (ytm-radio--initial-home-refreshed nil)
         (ytm-radio--login-process nil)
         (ytm-radio-helper-auth-file auth-file)
         captured-output
         captured-continuation)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'ytm-radio--show-buffer)
                     (lambda (_buffer) nil))
                    ((symbol-function 'ytm-radio--start-login)
                     (lambda (output &optional _restart-running after-success)
                       (setq captured-output output
                             captured-continuation after-success))))
            (ytm-radio)
            (should (equal captured-output auth-file))
            (should (functionp captured-continuation))))
      (delete-directory directory t))))

(ert-deftest ytm-radio-render-shows-non-track-items ()
  "Render albums, playlists, and other non-track items in the browser buffer."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:home"
                  :kind 'youtube-music-home
                  :title "YouTube Music Home"
                  :url "https://music.youtube.com/"
                  :tracks nil
                  :items '(((type . "album")
                            (id . "MPRE1")
                            (title . "Album Title")
                            (subtitle . "Artist")
                            (browse-id . "MPRE1")
                            (url . "https://music.youtube.com/browse/MPRE1")))))
         (ytm-radio--browser-view 'home)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))
           :home-continuation "next-page"
           :home-continuation-known t))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render)
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p "YouTube Music Home" (buffer-string)))
      (should (string-match-p "01[[:space:]]+Album Title"
                              (buffer-string)))
      (should (string-match-p "Album Title[^\n]*\nALBM[[:space:]]+Artist"
                              (buffer-string)))
      (goto-char (point-min))
      (search-forward "Album Title")
      (should (eq (button-get (button-at (match-beginning 0)) 'face)
                  'ytm-radio-item-title)))))

(ert-deftest ytm-radio-render-track-rating-indicators ()
  "Render liked and disliked markers directly after track titles."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:home"
                  :kind 'youtube-music-home
                  :title "YouTube Music Home"
                  :url "https://music.youtube.com/"
                  :items '(((type . "track")
                            (id . "liked")
                            (title . "Liked Song")
                            (url . "https://music.youtube.com/watch?v=liked")
                            (like-status . "like"))
                           ((type . "track")
                            (id . "disliked")
                            (title . "Disliked Song")
                            (url . "https://music.youtube.com/watch?v=disliked")
                            (like-status . "dislike")))))
         (ytm-radio--browser-view 'home)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (let ((case-fold-search nil))
        (should (string-match-p (regexp-quote "Liked Song ▲")
                                (buffer-string)))
        (should (string-match-p (regexp-quote "Disliked Song ▼")
                                (buffer-string)))
        (should-not (string-match-p "Liked Song[[:space:]]\\{2,\\}▲"
                                    (buffer-string)))
        (should-not (string-match-p "Disliked Song[[:space:]]\\{2,\\}▼"
                                    (buffer-string)))
        (goto-char (point-min))
        (search-forward " ▲")
        (should-not (get-text-property (1+ (match-beginning 0)) 'button))
        (should-not (get-text-property (1+ (match-beginning 0)) 'action))
        (should-not (get-text-property (1+ (match-beginning 0)) 'follow-link))
        (search-forward " ▼")
        (should-not (get-text-property (1+ (match-beginning 0)) 'button))))))

(ert-deftest ytm-radio-render-explore-track-rating-indicators ()
  "Render Explore track rating markers directly after track titles."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:explore:new"
                  :kind 'youtube-music-explore-section
                  :title "New releases"
                  :url "https://music.youtube.com/explore"
                  :items '(((type . "track")
                            (id . "liked")
                            (title . "Explore Song")
                            (url . "https://music.youtube.com/watch?v=liked")
                            (like-status . "like")))))
         (ytm-radio--browser-view 'explore)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p (regexp-quote "Explore Song ▲")
                              (buffer-string))))))

(ert-deftest ytm-radio-render-home-rating-from-cached-library-state ()
  "Render Home track ratings known from another cached source."
  (let* ((home-source (ytm-radio--make-source
                       :id "ytm:home:listen-again"
                       :kind 'youtube-music-home-section
                       :title "Listen again"
                       :url "https://music.youtube.com/"
                       :items '(((type . "track")
                                 (id . "2KoWN3sAFms")
                                 (title . "bonus funk")
                                 (url . "https://music.youtube.com/watch?v=2KoWN3sAFms")))))
         (library-source (ytm-radio--make-source
                          :id "ytm:library:songs"
                          :kind 'youtube-music-library-section
                          :title "Library Songs"
                          :url "https://music.youtube.com/library/songs"
                          :items '(((type . "track")
                                    (id . "2KoWN3sAFms")
                                    (title . "bonus funk")
                                    (url . "https://music.youtube.com/watch?v=2KoWN3sAFms")
                                    (like-status . "like")))))
         (ytm-radio--browser-view 'home)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt home-source :id) home-source)
                          (cons (map-elt library-source :id) library-source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p (regexp-quote "bonus funk ▲")
                              (buffer-string))))))

(ert-deftest ytm-radio-render-item-account-status-indicators ()
  "Render saved and subscribed markers after non-track item titles."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:home"
                  :kind 'youtube-music-home
                  :title "YouTube Music Home"
                  :url "https://music.youtube.com/"
                  :items '(((type . "album")
                            (id . "MPRE1")
                            (title . "Saved Album")
                            (browse-id . "MPRE1")
                            (in-library . t))
                           ((type . "artist")
                            (id . "UC1")
                            (title . "Subscribed Artist")
                            (browse-id . "UC1")
                            (subscribed . t)))))
         (ytm-radio--browser-view 'home)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p (regexp-quote "Saved Album [B]")
                              (buffer-string)))
      (should (string-match-p (regexp-quote "Subscribed Artist [✔]")
                              (buffer-string))))))

(ert-deftest ytm-radio-track-rating-indicator-preserves-icon-face ()
  "Keep Nerd Icons face properties on rating markers."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Liked Song"
                :url "https://music.youtube.com/watch?v=v1"
                :like-status 'like)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name _fallback)
                 (propertize "I" 'face 'nerd-icons-test-face))))
      (let ((indicator (ytm-radio--track-rating-indicator track)))
        (should (equal indicator " I"))
        (should (eq (get-text-property 1 'face indicator)
                    'nerd-icons-test-face))))))

(ert-deftest ytm-radio-render-library-items-are-compact ()
  "Render Library song items compactly while preserving ratings."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:library:songs"
                  :kind 'youtube-music-library-section
                  :title "Library Songs"
                  :url "https://music.youtube.com/library/songs"
                  :tracks nil
                  :items '(((type . "track")
                            (id . "v1")
                            (title . "Let Her Go")
                            (artist . "Passenger")
                            (album . "All The Little Lights")
                            (duration . 253)
                            (like-status . "like")
                            (url . "https://music.youtube.com/watch?v=v1")))))
         (ytm-radio--browser-view 'library)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p "01[[:space:]]+Let Her Go"
                              (buffer-string)))
      (should-not (string-match-p
                   "Songs[[:space:]]+Albums[[:space:]]+Artists"
                   (buffer-string)))
      (should-not (string-match-p "Passenger - All The Little Lights"
                                  (buffer-string)))
      (should (string-match-p (regexp-quote "Let Her Go ▲")
                              (buffer-string))))))

(ert-deftest ytm-radio-render-liked-music-hides-rating-indicators ()
  "Render Liked Music without redundant liked markers."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:library:liked"
                  :kind 'youtube-music-liked
                  :title "Liked Music"
                  :url "https://music.youtube.com/playlist?list=LM"
                  :tracks nil
                  :items '(((type . "track")
                            (id . "v1")
                            (title . "Liked Track")
                            (like-status . "like")
                            (url . "https://music.youtube.com/watch?v=v1")))))
         (ytm-radio--browser-view 'library)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p "01[[:space:]]+Liked Track"
                              (buffer-string)))
      (should-not (string-match-p (regexp-quote "Liked Track ▲")
                                  (buffer-string))))))

(ert-deftest ytm-radio-render-library-items-hide-library-status-marker ()
  "Render Library albums/playlists without redundant bookmark markers."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:library:playlists"
                  :kind 'youtube-music-library-section
                  :title "Library Playlists"
                  :url "https://music.youtube.com/library/playlists"
                  :tracks nil
                  :items '(((type . "playlist")
                            (id . "VLPL1")
                            (title . "Lofi Loft")
                            (browse-id . "VLPL1")
                            (in-library . t)))))
         (ytm-radio--browser-view 'library)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p "Lofi Loft" (buffer-string)))
      (should-not (string-match-p (regexp-quote "Lofi Loft [B]")
                                  (buffer-string))))))

(ert-deftest ytm-radio-section-view-does-not-duplicate-title ()
  "Render focused section views with one section title."
  (let* ((item '((id . "v1")
                 (type . "track")
                 (title . "Track")
                 (url . "https://music.youtube.com/watch?v=v1")))
         (source (ytm-radio--make-source
                  :id "ytm:home:listen"
                  :kind 'youtube-music-home-section
                  :title "Listen again"
                  :items (list item)))
         (ytm-radio--browser-view
          (list (cons :kind 'section)
                (cons :source-id (map-elt source :id))
                (cons :title "Listen again")))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render)
    (with-current-buffer "*ytm-radio*"
      (goto-char (point-min))
      (should (search-forward "Listen again" nil t))
      (should-not (search-forward "Listen again" nil t)))))

(ert-deftest ytm-radio-home-continuation-is-not-rendered-as-footer ()
  "Do not render Home continuation as an explicit control."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:home:listen"
                  :kind 'youtube-music-home-section
                  :title "Listen again"
                  :items nil))
         (ytm-radio--browser-view 'home)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))
           :home-continuation "next-page"
           :home-continuation-known t))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render)
    (with-current-buffer "*ytm-radio*"
      (should-not
       (string-match-p "Load more Home sections" (buffer-string))))))

(ert-deftest ytm-radio-home-lazy-load-starts-near-buffer-end ()
  "Start Home continuation loading when the visible window reaches the end."
  (let ((ytm-radio--browser-view 'home)
        (ytm-radio--state
         (ytm-radio--make-state
          :home-continuation "next-page"
          :home-continuation-known t))
        (ytm-radio--home-loading nil)
        (ytm-radio--home-process nil)
        (ytm-radio-home-lazy-load-margin 1)
        started)
    (with-temp-buffer
      (insert "one\ntwo\nthree\n")
      (goto-char (point-min))
      (cl-letf (((symbol-function 'window-live-p)
                 (lambda (_window) t))
                ((symbol-function 'window-buffer)
                 (lambda (_window) (current-buffer)))
                ((symbol-function 'window-end)
                 (lambda (_window &optional _update)
                   (line-beginning-position 3)))
                ((symbol-function 'get-buffer-window)
                 (lambda (_buffer &optional _all-frames) 'window))
                ((symbol-function 'ytm-radio--start-home-load)
                 (lambda (&optional append)
                   (setq started append))))
        (ytm-radio--maybe-lazy-load-home)
        (should started)))))

(ert-deftest ytm-radio-apply-home-data-replaces-then-appends ()
  "Replace Home on first page and append continuation pages."
  (let ((ytm-radio--state (ytm-radio--make-state))
        (ytm-radio--player (ytm-radio--make-player))
        (first '((sources
                  ((id . "ytm:home:listen")
                   (kind . "youtube-music-home-section")
                   (title . "Listen again")
                   (items . nil)))
                 (continuation . "next-page")))
        (next '((sources
                 ((id . "ytm:home:mixed")
                  (kind . "youtube-music-home-section")
                  (title . "Mixed for you")
                  (items . nil)))
                (continuation . nil))))
    (cl-letf (((symbol-function 'ytm-radio--save) #'ignore)
              ((symbol-function 'ytm-radio--render) #'ignore))
      (ytm-radio--apply-home-helper-data first nil)
      (should (assoc "ytm:home:listen" (ytm-radio--sources)))
      (should (equal (ytm-radio--home-continuation) "next-page"))
      (should (equal (map-elt ytm-radio--state :home-continuation)
                     "next-page"))
      (should (map-elt ytm-radio--state :home-continuation-known))
      (ytm-radio--apply-home-helper-data next t)
      (should (assoc "ytm:home:listen" (ytm-radio--sources)))
      (should (assoc "ytm:home:mixed" (ytm-radio--sources)))
      (should-not (ytm-radio--home-continuation))
      (should (map-elt ytm-radio--state :home-continuation-known)))))

(ert-deftest ytm-radio-imenu-indexes-sectioned-views ()
  "Expose Home, Explore, and Library sections through imenu."
  (let* ((home (ytm-radio--make-source
                :id "ytm:home:listen"
                :kind 'youtube-music-home-section
                :title "Listen again"
                :items nil))
         (explore (ytm-radio--make-source
                   :id "ytm:explore:new"
                   :kind 'youtube-music-explore-section
                   :title "New releases"
                   :items nil))
         (library (ytm-radio--make-source
                   :id "ytm:library:songs"
                   :kind 'youtube-music-library-section
                   :title "Library Songs"
                   :items nil))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt home :id) home)
                          (cons (map-elt explore :id) explore)
                          (cons (map-elt library :id) library))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (should (eq imenu-create-index-function
                  #'ytm-radio--imenu-create-index)))
    (let ((ytm-radio--browser-view 'home))
      (ytm-radio--render)
      (with-current-buffer "*ytm-radio*"
        (should (equal (mapcar #'car (ytm-radio--imenu-create-index))
                       '("Listen again")))))
    (let ((ytm-radio--browser-view 'library))
      (ytm-radio--render)
      (with-current-buffer "*ytm-radio*"
        (should (equal (mapcar #'car (ytm-radio--imenu-create-index))
                       '("Library Songs")))))))

(ert-deftest ytm-radio-select-browser-view-uses-cached-targets ()
  "Switching views uses cached sources without starting helper loads."
  (let* ((explore (ytm-radio--make-source
                   :id "ytm:explore:new"
                   :kind 'youtube-music-explore-section
                   :title "New releases"))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt explore :id) explore))))
         (ytm-radio--player (ytm-radio--make-player))
         started)
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--start-helper-target-load)
               (lambda (&rest _args) (setq started t))))
      (ytm-radio--select-browser-view 'explore)
      (should (eq ytm-radio--browser-view 'explore))
      (should-not started))))

(ert-deftest ytm-radio-select-browser-view-loads-uncached-target-async ()
  "Switching to uncached Explore or Library starts asynchronous loading."
  (let ((ytm-radio--state (ytm-radio--make-state))
        (ytm-radio--player (ytm-radio--make-player))
        started)
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--start-helper-target-load)
               (lambda (target label view)
                 (setq started (list target label view)))))
      (ytm-radio--select-browser-view 'explore)
      (should (equal started '("explore" "explore" explore))))
    (setq started nil)
    (cl-letf (((symbol-function 'ytm-radio--start-helper-target-load)
               (lambda (target label view)
                 (setq started (list target label view)))))
      (ytm-radio--select-browser-view 'library)
      (should (equal started '("library" "library" library))))))

(ert-deftest ytm-radio-select-browser-view-restores-root-position ()
  "Remember independent point positions for root browser views."
  (let* ((home-a (ytm-radio--make-track
                  :id "home-a"
                  :title "Home A"
                  :url "https://music.youtube.com/watch?v=home-a"))
         (home-b (ytm-radio--make-track
                  :id "home-b"
                  :title "Home B"
                  :url "https://music.youtube.com/watch?v=home-b"))
         (library-a (ytm-radio--make-track
                     :id "library-a"
                     :title "Library A"
                     :url "https://music.youtube.com/watch?v=library-a"))
         (library-b (ytm-radio--make-track
                     :id "library-b"
                     :title "Library B"
                     :url "https://music.youtube.com/watch?v=library-b"))
         (home (ytm-radio--make-source
                :id "ytm:home:listen-again"
                :kind 'youtube-music-home-section
                :title "Listen again"
                :tracks (list home-a home-b)))
         (library (ytm-radio--make-source
                   :id "ytm:library:songs"
                   :kind 'youtube-music-library-section
                   :title "Library Songs"
                   :tracks (list library-a library-b)))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt home :id) home)
                          (cons (map-elt library :id) library))))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--browser-view 'home)
         (ytm-radio--browser-history nil)
         (ytm-radio--root-view-positions nil)
         (ytm-radio--loaded t))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render-browser t)
    (with-current-buffer "*ytm-radio*"
      (goto-char (point-min))
      (search-forward "Home B")
      (beginning-of-line)
      (should (equal (ytm-radio--item-title
                      (ytm-radio--line-item-at-point))
                     "Home B")))
    (ytm-radio--select-browser-view 'library)
    (with-current-buffer "*ytm-radio*"
      (goto-char (point-min))
      (search-forward "Library B")
      (beginning-of-line)
      (should (equal (ytm-radio--item-title
                      (ytm-radio--line-item-at-point))
                     "Library B")))
    (ytm-radio--select-browser-view 'home)
    (with-current-buffer "*ytm-radio*"
      (should (equal (ytm-radio--item-title
                      (ytm-radio--line-item-at-point))
                     "Home B")))
    (ytm-radio--select-browser-view 'library)
    (with-current-buffer "*ytm-radio*"
      (should (equal (ytm-radio--item-title
                      (ytm-radio--line-item-at-point))
                     "Library B")))))

(ert-deftest ytm-radio-search-loads-asynchronously ()
  "Run YouTube Music search through the async helper path."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:search:30:1:songs"
                  :kind 'youtube-music-search-section
                  :title "Songs"
                  :url "https://music.youtube.com/search?q=30"
                  :items nil
                  :tracks nil))
         (ytm-radio-helper-auth-file nil)
         (ytm-radio-helper-library-limit 12)
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--loaded t)
         (ytm-radio--browser-view 'home)
         (ytm-radio--browser-load-process nil)
         captured-arguments)
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq captured-arguments arguments)
                 (funcall success 'data)
                 nil))
              ((symbol-function 'ytm-radio--helper-sources)
               (lambda (_data) (list source)))
              ((symbol-function 'ytm-radio--save) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-search "30")
      (should (equal captured-arguments
                     '("search" "30" "--limit" "12")))
      (should (eq (ytm-radio--view-kind) 'search))
      (should (ytm-radio--source "ytm:search:30:1:songs"))
      (should-not ytm-radio--browser-load-process)
      (should-not ytm-radio--browser-loading-message))))

(ert-deftest ytm-radio-search-ignores-stale-helper-callback ()
  "Ignore search callbacks that no longer match the active request token."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:search:late:songs"
                  :kind 'youtube-music-search-section
                  :title "Late"
                  :url "https://music.youtube.com/search?q=late"))
         (ytm-radio-helper-auth-file nil)
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--loaded t)
         (ytm-radio--browser-view 'home)
         (ytm-radio--browser-load-process nil)
         success-callback
         saved)
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (_arguments success _error-callback)
                 (setq success-callback success)
                 'old-process))
              ((symbol-function 'ytm-radio--helper-sources)
               (lambda (_data) (list source)))
              ((symbol-function 'ytm-radio--save)
               (lambda () (setq saved t)))
              ((symbol-function 'message) #'ignore))
      (ytm-radio-search "late")
      (setq ytm-radio--browser-load-token (ytm-radio--new-request-token))
      (funcall success-callback 'data)
      (should-not (ytm-radio--source "ytm:search:late:songs"))
      (should-not saved)
      (should (eq ytm-radio--browser-load-process 'old-process)))))

(ert-deftest ytm-radio-liked-import-uses-async-target-loader ()
  "Import liked songs through the shared async target loader."
  (let ((ytm-radio--state (ytm-radio--make-state))
        (ytm-radio--player (ytm-radio--make-player))
        (ytm-radio--loaded t)
        captured)
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--start-helper-target-load)
               (lambda (target label view)
                 (setq captured (list target label view)))))
      (ytm-radio-import-ytmusic-liked)
      (should (equal captured '("liked" "liked songs" library))))))

(ert-deftest ytm-radio-refresh-liked-section-bypasses-helper-cache ()
  "Refreshing a liked songs section requests fresh helper data."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:library:liked"
                  :kind 'youtube-music-liked
                  :title "Liked Songs"
                  :tracks nil))
         (view (list (cons :kind 'section)
                     (cons :source-id "ytm:library:liked")
                     (cons :title "Liked Songs")
                     (cons :origin-view 'library)))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--browser-view view)
         (ytm-radio--browser-load-process nil)
         (ytm-radio--loaded t)
         captured)
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--start-helper-target-load)
               (lambda (target label loading-view &optional restore-entry fresh)
                 (setq captured
                       (list target label loading-view
                             (map-elt restore-entry :view)
                             fresh)))))
      (ytm-radio-refresh)
      (should (equal captured
                     (list "liked" "liked songs" view view t))))))

(ert-deftest ytm-radio-render-shows-detail-header-metadata ()
  "Render detail header sources with thumbnail metadata and subtitle."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:browse:UC1:header"
                  :kind 'youtube-music-artist
                  :title "Chill girl Vibes"
                  :url "https://music.youtube.com/browse/UC1"
                  :tracks nil
                  :items nil
                  :subtitle "1.2K subscribers"
                  :thumbnail-url "https://example.com/avatar.jpg"))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt source :id)))
                (cons :title "Chill girl Vibes")))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--item-thumbnail-image)
               (lambda (_item) nil)))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p "Chill girl Vibes" (buffer-string)))
      (should (string-match-p "1.2K subscribers" (buffer-string)))
      (should-not (string-match-p "0 items / 0 tracks" (buffer-string))))))

(ert-deftest ytm-radio-render-detail-header-account-status ()
  "Render account status markers in detail headers."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:browse:VLPL1:header"
                  :kind 'youtube-music-playlist
                  :title "Saved Playlist"
                  :url "https://music.youtube.com/browse/VLPL1"
                  :items nil
                  :tracks nil
                  :in-library t))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt source :id)))
                (cons :browse-id "VLPL1")
                (cons :title "Saved Playlist")))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--item-thumbnail-image)
               (lambda (_item) nil))
              ((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p (regexp-quote "Saved Playlist [B]")
                              (buffer-string)))
      (should (string-match-p "Saved" (buffer-string)))
      (should-not (string-match-p "Toggle library" (buffer-string))))))

(ert-deftest ytm-radio-render-artist-detail-header-subscription-action ()
  "Render artist/channel subscription actions without library action text."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:browse:UC1:header"
                  :kind 'youtube-music-artist
                  :title "Chill Artist"
                  :url "https://music.youtube.com/browse/UC1"
                  :items nil
                  :tracks nil
                  :subscribed nil))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt source :id)))
                (cons :browse-id "UC1")
                (cons :title "Chill Artist")))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--item-thumbnail-image)
               (lambda (_item) nil))
              ((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p "Subscribe" (buffer-string)))
      (should-not (string-match-p "Toggle subscription" (buffer-string)))
      (should-not (string-match-p "Toggle library" (buffer-string))))))

(ert-deftest ytm-radio-open-at-point-does-not-enter-detail-header ()
  "Do not treat a rendered detail header body as an enterable section."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:browse:UC1:header"
                  :kind 'youtube-music-artist
                  :title "Chill Artist"
                  :url "https://music.youtube.com/browse/UC1"
                  :items nil
                  :tracks nil
                  :subscribed nil))
         (ytm-radio--loaded t)
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt source :id)))
                (cons :browse-id "UC1")
                (cons :title "Chill Artist")))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--source-header-cover-image)
               (lambda (_source) nil)))
      (ytm-radio--render-browser))
    (with-current-buffer "*ytm-radio*"
      (goto-char (point-min))
      (search-forward "Chill Artist")
      (should-error (ytm-radio-open-at-point) :type 'user-error)
      (should (eq (ytm-radio--view-kind) 'detail)))))

(ert-deftest ytm-radio-detail-subscription-button-label-changes-icon ()
  "Use distinct subscription button icons for subscribed and unsubscribed states."
  (let ((unsubscribed (ytm-radio--make-source
                       :id "ytm:browse:UC1:header"
                       :kind 'youtube-music-artist
                       :title "Artist"
                       :subscribed nil))
        (subscribed (ytm-radio--make-source
                     :id "ytm:browse:UC1:header"
                     :kind 'youtube-music-artist
                     :title "Artist"
                     :subscribed t)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (name _fallback) name)))
      (should (string-match-p
               "nf-md-account_plus_outline"
               (ytm-radio--detail-subscription-button-label unsubscribed)))
      (should (string-match-p
               "nf-md-account_check"
               (ytm-radio--detail-subscription-button-label subscribed))))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (should (string-equal
               (ytm-radio--detail-subscription-button-label subscribed)
               "[✔] Subscribed")))))

(ert-deftest ytm-radio-detail-header-can-use-cover-slices ()
  "Render detail header metadata beside a sliced cover when available."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:browse:MPRE1:header"
                  :kind 'youtube-music-album
                  :title "Smoke Rings"
                  :url "https://music.youtube.com/browse/MPRE1"
                  :tracks nil
                  :items nil
                  :subtitle "Album - Kolisnik & LoFi Beats"
                  :thumbnail-url "https://example.com/cover.jpg")))
    (with-temp-buffer
      (cl-letf (((symbol-function 'ytm-radio--source-header-cover-image)
                 (lambda (_source) (list 'cover-image 90 10 3)))
                ((symbol-function 'ytm-radio--detail-view-tracks)
                 (lambda () nil)))
        (ytm-radio--insert-source-header source))
      (should (string-match-p "Smoke Rings" (buffer-string)))
      (should (string-match-p "Album • Kolisnik & LoFi Beats"
                              (buffer-string)))
      (goto-char (point-min))
      (let (display)
        (while (and (not display) (< (point) (point-max)))
          (setq display (get-text-property (point) 'display))
          (forward-char 1))
        (should (equal display '((slice 0 0 1.0 10) cover-image)))))))

(ert-deftest ytm-radio-detail-header-cover-slices-overlap ()
  "Overlap adjacent detail header cover slices to avoid row gaps."
  (let ((cover (list 'cover-image 90 10 3)))
    (should (equal (get-text-property
                    0 'display
                    (ytm-radio--detail-header-cover-slice cover 0))
                   '((slice 0 0 1.0 10) cover-image)))
    (should (equal (get-text-property
                    0 'display
                    (ytm-radio--detail-header-cover-slice cover 1))
                   '((slice 0 9 1.0 10) cover-image)))))

(ert-deftest ytm-radio-detail-header-rows-use-cover-line-height ()
  "Keep sliced detail cover rows at the same height as their newlines."
  (let ((source (ytm-radio--make-source
                 :id "ytm:browse:MPRE1:header"
                 :kind 'youtube-music-album
                 :title "Smoke Rings"
                 :subtitle "Album - Kolisnik & LoFi Beats")))
    (with-temp-buffer
      (cl-letf (((symbol-function 'ytm-radio--source-header-cover-image)
                 (lambda (_source) (list 'cover-image 90 10 3)))
                ((symbol-function 'ytm-radio--detail-view-tracks)
                 (lambda () nil)))
        (ytm-radio--insert-source-header source t))
      (let (line-heights)
        (goto-char (point-min))
        (while (search-forward "\n" nil t)
          (push (get-text-property (1- (point)) 'line-height)
                line-heights))
        (should (equal (seq-filter #'identity (nreverse line-heights))
                       '((10 . 10) (10 . 10) (10 . 10))))))))

(ert-deftest ytm-radio-detail-header-row-height-adds-cjk-padding ()
  "Apply padded detail header row height to cover and text rows."
  (let* ((row-height (ytm-radio--detail-header-row-height))
         (source (ytm-radio--make-source
                  :id "ytm:browse:VLPL1:header"
                  :kind 'youtube-music-playlist
                  :title "新加坡百佳音乐视频"
                  :subtitle "排行榜 - YouTube Music"))
         cover-called)
    (with-temp-buffer
      (cl-letf (((symbol-function 'ytm-radio--source-header-cover-image)
                 (lambda (_source)
                   (setq cover-called t)
                   (list 'cover-image (* row-height 3) row-height 3)))
                ((symbol-function 'ytm-radio--detail-view-tracks)
                 (lambda () nil)))
        (ytm-radio--insert-source-header source t))
      (should cover-called)
      (goto-char (point-min))
      (should (search-forward "新加坡百佳音乐视频" nil t))
      (should (equal (get-text-property (match-beginning 0) 'line-height)
                     (cons row-height row-height)))
      (let (line-heights)
        (goto-char (point-min))
        (while (search-forward "\n" nil t)
          (push (get-text-property (1- (point)) 'line-height)
                line-heights))
        (should (equal (seq-filter #'identity (nreverse line-heights))
                       (make-list 3
                                  (cons row-height row-height))))))))

(ert-deftest ytm-radio-detail-header-actions-align-with-last-cover-slice ()
  "Place detail header actions on the last cover row."
  (let* ((track (ytm-radio--make-track
                 :id "v1"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=v1"))
         (source (ytm-radio--make-source
                  :id "ytm:browse:MPRE1:header"
                  :kind 'youtube-music-album
                  :title "Smoke Rings"
                  :subtitle "Album - Kolisnik & LoFi Beats")))
    (with-temp-buffer
      (cl-letf (((symbol-function 'ytm-radio--source-header-cover-image)
                 (lambda (_source) (list 'cover-image 90 10 6)))
                ((symbol-function 'ytm-radio--detail-view-tracks)
                 (lambda () (list track))))
        (ytm-radio--insert-source-header source t))
      (goto-char (point-min))
      (should (= (line-number-at-pos (point)) 1))
      (should (search-forward "Play" nil t))
      (should (= (line-number-at-pos (match-beginning 0)) 6)))))

(ert-deftest ytm-radio-detail-headers-use-square-layout-for-artwork ()
  "Use square detail covers for album, playlist, artist, and channel headers."
  (let ((album (ytm-radio--make-source
                :id "ytm:browse:MPRE1:header"
                :kind 'youtube-music-album
                :title "Album"))
        (playlist (ytm-radio--make-source
                   :id "ytm:browse:VLPL1:header"
                   :kind 'youtube-music-playlist
                   :title "Playlist"))
        (artist (ytm-radio--make-source
                 :id "ytm:browse:UC1:header"
                 :kind 'youtube-music-artist
                 :title "Artist"))
        (channel (ytm-radio--make-source
                  :id "ytm:channel:UC1:header"
                  :kind 'youtube-channel
                  :title "Channel"))
        (detail (ytm-radio--make-source
                 :id "ytm:browse:detail:header"
                 :kind 'youtube-music-detail
                 :title "Detail")))
    (should (ytm-radio--source-square-header-p album))
    (should (ytm-radio--source-square-header-p playlist))
    (should (ytm-radio--source-square-header-p artist))
    (should (ytm-radio--source-square-header-p channel))
    (should-not (ytm-radio--source-square-header-p detail))))

(ert-deftest ytm-radio-playlist-detail-header-uses-placeholder-cover ()
  "Render a square placeholder cover for playlist headers without artwork."
  (let ((source (ytm-radio--make-source
                 :id "ytm:browse:VLPL1:header"
                 :kind 'youtube-music-playlist
                 :title "Lofi Loft"
                 :subtitle "Playlist - Evil Needle")))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _display) t))
              ((symbol-function 'ytm-radio--svg-detail-header-placeholder-image)
               (lambda (_source &optional _row-height _row-count)
                 'placeholder-cover)))
      (let ((cover (ytm-radio--source-header-cover-image source)))
        (should (equal (car cover) 'placeholder-cover))
        (should (= (nth 1 cover) (ytm-radio--detail-header-cover-size)))))))

(ert-deftest ytm-radio-detail-header-cover-download-rerenders-browser ()
  "Refresh detail headers when an uncached cover download completes."
  (let ((source (ytm-radio--make-source
                 :id "ytm:browse:MPRE1:header"
                 :kind 'youtube-music-album
                 :title "Album"
                 :thumbnail-url "https://example.invalid/cover.jpg"))
        captured-callback
        rendered)
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t))
              ((symbol-function 'ytm-radio--ensure-cover-file)
               (lambda (_url callback)
                 (setq captured-callback callback)
                 nil))
              ((symbol-function 'ytm-radio--svg-detail-header-placeholder-image)
               (lambda (&rest _arguments) 'placeholder-cover))
              ((symbol-function 'ytm-radio--render-browser)
               (lambda (&rest _arguments) (setq rendered t))))
      (should (ytm-radio--source-header-cover-image source))
      (should (functionp captured-callback))
      (funcall captured-callback "https://example.invalid/cover.jpg" "/tmp/cover.jpg")
      (should rendered))))

(ert-deftest ytm-radio-album-detail-header-renders-title-only-header ()
  "Render album headers with real titles even when metadata is missing."
  (let ((source (ytm-radio--make-source
                 :id "ytm:browse:MPRE1:header"
                 :kind 'youtube-music-album
                 :title "Smoke Rings"
                 :items nil
                 :tracks nil)))
    (should (ytm-radio--source-header-p source))
    (should-not (ytm-radio--empty-detail-header-p source))
    (with-temp-buffer
      (cl-letf (((symbol-function 'ytm-radio--source-header-cover-image)
                 (lambda (_source) (list 'cover-image 90 10 3)))
                ((symbol-function 'ytm-radio--detail-view-tracks)
                 (lambda () nil)))
        (ytm-radio--insert-source-header source t))
      (should (string-match-p "Smoke Rings" (buffer-string))))))

(ert-deftest ytm-radio-album-detail-header-uses-opening-item-context ()
  "Use the opening album item metadata to enrich the detail header."
  (let* ((item '((type . "album")
                 (title . "Smoke Rings")
                 (subtitle . "Album - 2026")
                 (thumbnail-url . "https://example.com/smoke-rings.jpg")))
         (source (ytm-radio--make-source
                  :id "ytm:browse:MPRE1:header"
                  :kind 'youtube-music-album
                  :title "Smoke Rings"
                  :items nil
                  :tracks nil))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :context item))))
    (should (equal (ytm-radio--source-thumbnail-url source)
                   "https://example.com/smoke-rings.jpg"))
    (should (equal (ytm-radio--source-subtitle source)
                   "Album • 2026"))))

(ert-deftest ytm-radio-browse-detail-sources-adds-context-header ()
  "Add a synthetic album/playlist header for single-source detail results."
  (let* ((track (ytm-radio--make-track
                 :id "v1"
                 :title "Whiskey On My Mind"
                 :url "https://music.youtube.com/watch?v=v1"
                 :duration 314))
         (source (ytm-radio--make-source
                  :id "ytm:browse:MPRE1"
                  :kind 'youtube-music-album
                  :title "Smoke Rings"
                  :url "https://music.youtube.com/browse/MPRE1"
                  :items (list track)
                  :tracks (list track)))
         (item '((type . "album")
                 (title . "Smoke Rings")
                 (subtitle . "Album - 2026")
                 (thumbnail-url . "https://example.com/smoke-rings.jpg")
                 (url . "https://music.youtube.com/browse/MPRE1")))
         (sources (ytm-radio--browse-detail-sources (list source) item))
         (header (car sources)))
    (should (= (length sources) 2))
    (should (eq (map-elt header :kind) 'youtube-music-album))
    (should (equal (map-elt header :id) "ytm:browse:MPRE1:header"))
    (should (equal (map-elt header :title) "Smoke Rings"))
    (should (equal (map-elt header :subtitle) "Album - 2026"))
    (should (equal (map-elt header :thumbnail-url)
                   "https://example.com/smoke-rings.jpg"))
    (should (eq (cadr sources) source))))

(ert-deftest ytm-radio-browse-detail-sources-adds-channel-context-header ()
  "Add a synthetic channel header for single-source detail results."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:browse:UC1"
                  :kind 'youtube-music-artist
                  :title "Artist"
                  :url "https://music.youtube.com/browse/UC1"
                  :items nil
                  :tracks nil))
         (item '((type . "channel")
                 (title . "Lofi Girl")
                 (subtitle . "5.13M monthly audience")
                 (thumbnail-url . "https://example.com/lofi-girl.jpg")
                 (browse-id . "UC1")
                 (subscribed . t)))
         (sources (ytm-radio--browse-detail-sources (list source) item))
         (header (car sources)))
    (should (= (length sources) 2))
    (should (eq (map-elt header :kind) 'youtube-channel))
    (should (equal (map-elt header :id) "ytm:browse:UC1:header"))
    (should (equal (map-elt header :title) "Lofi Girl"))
    (should (equal (map-elt header :subtitle) "5.13M monthly audience"))
    (should (equal (map-elt header :thumbnail-url)
                   "https://example.com/lofi-girl.jpg"))
    (should (map-elt header :subscribed))
    (should (eq (cadr sources) source))))

(ert-deftest ytm-radio-browse-detail-header-keeps-positive-account-state ()
  "Keep saved/subscribed detail markers when source or opener knows them."
  (let* ((subscribed-source
          (ytm-radio--make-source
           :id "ytm:browse:UC1"
           :kind 'youtube-music-artist
           :title "Artist"
           :url "https://music.youtube.com/browse/UC1"
           :items nil
           :tracks nil
           :subscribed t))
         (stale-unsubscribed-item
          '((type . "artist")
            (title . "Artist")
            (browse-id . "UC1")
            (subscribed . nil)))
         (subscribed-header
          (car (ytm-radio--browse-detail-sources
                (list subscribed-source)
                stale-unsubscribed-item)))
         (saved-item
          '((type . "album")
            (title . "Album")
            (browse-id . "MPRE1")
            (in-library . t)))
         (unsaved-source
          (ytm-radio--make-source
           :id "ytm:browse:MPRE1"
           :kind 'youtube-music-album
           :title "Album"
           :url "https://music.youtube.com/browse/MPRE1"
           :items nil
           :tracks nil
           :in-library nil
           :in-library-known t))
         (saved-header
          (car (ytm-radio--browse-detail-sources
                (list unsaved-source)
                saved-item))))
    (should (map-elt subscribed-header :subscribed))
    (should (map-elt saved-header :in-library))
    (should (map-elt saved-header :in-library-known))))

(ert-deftest ytm-radio-browse-detail-header-preserves-helper-header-state ()
  "Keep helper header account state when enriching it with opener context."
  (let* ((helper-header
          (ytm-radio--make-source
           :id "ytm:browse:UC1:header"
           :kind 'youtube-music-artist
           :title "Artist"
           :url "https://music.youtube.com/browse/UC1"
           :items nil
           :tracks nil
           :subscribed t
           :subscribed-known t))
         (songs
          (ytm-radio--make-source
           :id "ytm:browse:UC1:1:songs"
           :kind 'youtube-music-detail-section
           :title "Songs"
           :url "https://music.youtube.com/browse/UC1"
           :items nil
           :tracks nil))
         (stale-context
          '((type . "artist")
            (title . "Artist")
            (browse-id . "UC1")
            (subscribed . nil)))
         (header
          (car (ytm-radio--browse-detail-sources
                (list helper-header songs)
                stale-context))))
    (should (equal (map-elt header :id) "ytm:browse:UC1:header"))
    (should (map-elt header :subscribed))
    (should (map-elt header :subscribed-known))))

(ert-deftest ytm-radio-browse-detail-sources-enriches-existing-header ()
  "Use opening item metadata when the helper returns a generic detail header."
  (let* ((track (ytm-radio--make-track
                 :id "v1"
                 :title "Someone Like You"
                 :url "https://music.youtube.com/watch?v=v1"
                 :duration 286))
         (header (ytm-radio--make-source
                  :id "ytm:browse:VLPL1:header"
                  :kind 'youtube-music-playlist
                  :title "Playlist"
                  :items nil
                  :tracks nil))
         (songs (ytm-radio--make-source
                 :id "ytm:browse:VLPL1:1:songs"
                 :kind 'youtube-music-detail-section
                 :title "Songs"
                 :items (list track)
                 :tracks (list track)))
         (item '((type . "playlist")
                 (title . "Adele Mix")
                 (subtitle . "Playlist - YouTube Music")
                 (browse-id . "VLPL1")
                 (thumbnail-url . "https://example.com/adele-mix.jpg")))
         (sources (ytm-radio--browse-detail-sources (list header songs) item))
         (enriched (car sources)))
    (should (= (length sources) 2))
    (should (equal (map-elt enriched :id) "ytm:browse:VLPL1:header"))
    (should (eq (map-elt enriched :kind) 'youtube-music-playlist))
    (should (equal (map-elt enriched :title) "Adele Mix"))
    (should (equal (map-elt enriched :subtitle) "Playlist - YouTube Music"))
    (should (equal (map-elt enriched :thumbnail-url)
                   "https://example.com/adele-mix.jpg"))
    (should (eq (cadr sources) songs))))

(ert-deftest ytm-radio-item-detail-header-kind-prefers-browse-id ()
  "Classify album-like playlist cards by their browse id."
  (should (eq (ytm-radio--item-detail-header-kind
               '((type . "playlist")
                 (browse-id . "MPREb_album")
                 (title . "30")))
              'youtube-music-album))
  (should (eq (ytm-radio--item-detail-header-kind
               '((type . "playlist")
                 (browse-id . "VLPL1")
                 (title . "Mix")))
              'youtube-music-playlist))
  (should (eq (ytm-radio--item-detail-header-kind
               '((type . "artist")
                 (browse-id . "UCartist")
                 (title . "Artist")))
              'youtube-music-artist))
  (should (eq (ytm-radio--item-detail-header-kind
               '((type . "channel")
                 (browse-id . "UCchannel")
                 (title . "Channel")))
              'youtube-channel)))

(ert-deftest ytm-radio-headingless-detail-source-requires-visible-header ()
  "Keep the content heading when the sibling detail header is not renderable."
  (let* ((track (ytm-radio--make-track
                 :id "v1"
                 :title "Someone Like You"
                 :url "https://music.youtube.com/watch?v=v1"))
         (content (ytm-radio--make-source
                   :id "ytm:browse:VLPL1"
                   :kind 'youtube-music-playlist
                   :title "Playlist"
                   :items (list track)
                   :tracks (list track)))
         (empty-header (ytm-radio--make-source
                        :id "ytm:browse:VLPL1:header"
                        :kind 'youtube-music-playlist
                        :title "Playlist"
                        :items nil
                        :tracks nil))
         (visible-header (ytm-radio--make-source
                          :id "ytm:browse:VLPL1:header"
                          :kind 'youtube-music-playlist
                          :title "Adele Mix"
                          :items nil
                          :tracks nil))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids '("ytm:browse:VLPL1:header"
                                    "ytm:browse:VLPL1")))))
    (let ((ytm-radio--state
           (ytm-radio--make-state
            :sources (list (cons (map-elt empty-header :id) empty-header)
                           (cons (map-elt content :id) content)))))
      (should-not (ytm-radio--headingless-detail-source-p content)))
    (let ((ytm-radio--state
           (ytm-radio--make-state
            :sources (list (cons (map-elt visible-header :id) visible-header)
                           (cons (map-elt content :id) content)))))
      (should (ytm-radio--headingless-detail-source-p content)))))

(ert-deftest ytm-radio-synthetic-album-header-renders-before-single-source ()
  "Render the synthesized album header before the single returned source."
  (let* ((track (ytm-radio--make-track
                 :id "v1"
                 :title "Whiskey On My Mind"
                 :url "https://music.youtube.com/watch?v=v1"
                 :duration 314))
         (source (ytm-radio--make-source
                  :id "ytm:browse:MPRE1"
                  :kind 'youtube-music-album
                  :title "Smoke Rings"
                  :url "https://music.youtube.com/browse/MPRE1"
                  :items (list track)
                  :tracks (list track)))
         (item '((type . "album")
                 (title . "Smoke Rings")
                 (subtitle . "Album - 2026")
                 (thumbnail-url . "https://example.com/smoke-rings.jpg")))
         (sources (ytm-radio--browse-detail-sources (list source) item))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (mapcar (lambda (source)
                                             (map-elt source :id))
                                           sources))
                (cons :context item)
                (cons :title "Smoke Rings")))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (mapcar (lambda (source)
                              (cons (map-elt source :id) source))
                            sources)))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--source-header-cover-image)
               (lambda (_source) (list 'cover-image 90 10 3))))
      (ytm-radio--render))
    (with-current-buffer "*ytm-radio*"
      (let ((contents (buffer-string)))
        (should (string-match-p "Smoke Rings" contents))
        (should (string-match-p "Album • 2026" contents))
        (should (string-match-p "1 song • 5 minutes" contents))
        (should (string-match-p "Whiskey On My Mind" contents))
        (should-not (string-match-p "Smoke Rings[[:space:]]+1 track"
                                    contents))))))

(ert-deftest ytm-radio-play-detail-view-sets-runtime-queue ()
  "Play detail headers through the runtime queue used by next/previous."
  (let* ((track-a (ytm-radio--make-track
                   :id "a"
                   :title "A"
                   :url "https://music.youtube.com/watch?v=abc123_DEF4"))
         (track-b (ytm-radio--make-track
                   :id "b"
                   :title "B"
                   :url "https://music.youtube.com/watch?v=def456_GHI7"))
         (source (ytm-radio--make-source
                  :id "detail"
                  :kind 'youtube-music-album
                  :title "Detail"
                  :tracks (list track-a track-b)
                  :items (list track-a track-b)))
         (ytm-radio--browser-view
          '((:kind . detail) (:source-ids . ("detail"))))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons "detail" source))))
         (ytm-radio--player (ytm-radio--make-player))
         played-track)
    (cl-letf (((symbol-function 'ytm-radio--play-track)
               (lambda (track)
                 (setq played-track track))))
      (ytm-radio--play-detail-view))
    (should (eq played-track track-a))
    (should (equal (map-elt ytm-radio--player :queue)
                   (list track-a track-b)))
    (should (= (map-elt ytm-radio--player :queue-index) 0))))

(ert-deftest ytm-radio-album-detail-header-summary-is-youtube-like ()
  "Format album and playlist detail summaries like YouTube Music."
  (let* ((track-a (ytm-radio--make-track
                   :id "a"
                   :title "A"
                   :url "https://music.youtube.com/watch?v=a"
                   :duration 3600))
         (track-b (ytm-radio--make-track
                   :id "b"
                   :title "B"
                   :url "https://music.youtube.com/watch?v=b"
                   :duration 2580))
         (header (ytm-radio--make-source
                  :id "ytm:browse:MPRE1:header"
                  :kind 'youtube-music-album
                  :title "Smoke Rings"
                  :items nil
                  :tracks nil))
         (songs (ytm-radio--make-source
                 :id "ytm:browse:MPRE1:1:songs"
                 :kind 'youtube-music-detail-section
                 :title "Songs"
                 :items (list track-a track-b)
                 :tracks (list track-a track-b)))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt header :id)
                                        (map-elt songs :id)))))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt header :id) header)
                          (cons (map-elt songs :id) songs)))))
    (should (equal (ytm-radio--detail-header-summary header)
                   "2 songs • 1 hour, 43 minutes"))))

(ert-deftest ytm-radio-playlist-detail-header-summary-keeps-item-track-split ()
  "Preserve item and track counts when playlist detail contains both."
  (let* ((track (ytm-radio--make-track
                 :id "a"
                 :title "A"
                 :url "https://music.youtube.com/watch?v=a"
                 :duration 286))
         (non-track '((type . "item")
                      (title . "Shuffle all")))
         (header (ytm-radio--make-source
                  :id "ytm:browse:VLPL1:header"
                  :kind 'youtube-music-playlist
                  :title "Adele Mix"
                  :items nil
                  :tracks nil))
         (songs (ytm-radio--make-source
                 :id "ytm:browse:VLPL1"
                 :kind 'youtube-music-playlist
                 :title "Playlist"
                 :items (list non-track track)
                 :tracks (list track)))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt header :id)
                                        (map-elt songs :id)))))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt header :id) header)
                          (cons (map-elt songs :id) songs)))))
    (should (equal (ytm-radio--detail-header-summary header)
                   "2 items / 1 track • 4 minutes"))))

(ert-deftest ytm-radio-artist-detail-header-uses-square-image ()
  "Render artist detail headers with a square image instead of a wide banner."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:browse:UC1:header"
                  :kind 'youtube-music-artist
                  :title "Chill girl Vibes"
                  :url "https://music.youtube.com/browse/UC1"
                  :tracks nil
                  :items nil
                  :subtitle "448K monthly audience"
                  :thumbnail-url "https://example.com/avatar.jpg"))
         cover-called)
    (with-temp-buffer
      (cl-letf (((symbol-function 'ytm-radio--source-header-cover-image)
                 (lambda (_source)
                   (setq cover-called t)
                   (list 'cover-image 90 10 3)))
                ((symbol-function 'ytm-radio--detail-view-tracks)
                 (lambda () nil)))
        (ytm-radio--insert-source-header source t))
      (should cover-called)
      (should (string-match-p "Chill girl Vibes" (buffer-string)))
      (should (string-match-p "448K monthly audience" (buffer-string))))))

(ert-deftest ytm-radio-detail-header-summary-uses-detail-tracks ()
  "Summarize tracks from the full detail view, not the header source."
  (let* ((track-a (ytm-radio--make-track
                   :id "a"
                   :title "A"
                   :url "https://music.youtube.com/watch?v=a"
                   :duration 60))
         (track-b (ytm-radio--make-track
                   :id "b"
                   :title "B"
                   :url "https://music.youtube.com/watch?v=b"
                   :duration 125))
         (header (ytm-radio--make-source
                  :id "ytm:browse:MPRE1:header"
                  :kind 'youtube-music-album
                  :title "Album"
                  :items nil
                  :tracks nil
                  :subtitle "Album - Artist"))
         (songs (ytm-radio--make-source
                 :id "ytm:browse:MPRE1:1:songs"
                 :kind 'youtube-music-detail-section
                 :title "Songs"
                 :items (list track-a track-b)
                 :tracks (list track-a track-b)))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt header :id)
                                        (map-elt songs :id)))))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt header :id) header)
                          (cons (map-elt songs :id) songs))))
         (ytm-radio--player (ytm-radio--make-player)))
    (should (equal (ytm-radio--detail-view-summary)
                   "2 tracks - 3m"))))

(ert-deftest ytm-radio-detail-view-hides-empty-header-and-generic-section-title ()
  "Do not render empty detail headers or internal fallback section titles."
  (let* ((track (ytm-radio--make-track
                 :id "v1"
                 :title "Nella Fantasia"
                 :url "https://music.youtube.com/watch?v=v1"))
         (header (ytm-radio--make-source
                  :id "ytm:browse:MPRE1:header"
                  :kind 'youtube-music-album
                  :title "Album"
                  :items nil
                  :tracks nil))
         (songs (ytm-radio--make-source
                 :id "ytm:browse:MPRE1:1:home-section-1"
                 :kind 'youtube-music-detail-section
                 :title "Home section 1"
                 :items (list track)
                 :tracks (list track)))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt header :id)
                                        (map-elt songs :id)))))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt header :id) header)
                          (cons (map-elt songs :id) songs))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render)
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p "Nella Fantasia" (buffer-string)))
      (should-not (string-match-p "Album[[:space:]]+0 tracks" (buffer-string)))
      (should-not (string-match-p "Home section 1" (buffer-string))))))

(ert-deftest ytm-radio-detail-prefix-matches-item-prefix-width ()
  "Render title and detail prefixes to the same width."
  (let* ((item '((type . "album")))
         (type-cell (ytm-radio--item-type-cell item))
         (prefix (ytm-radio--item-prefix-string 1 type-cell item))
         (detail-prefix
          (ytm-radio--item-detail-prefix-string 1 type-cell item)))
    (with-temp-buffer
      (ytm-radio--insert-item-prefix prefix detail-prefix)
      (let ((title-column (current-column)))
        (erase-buffer)
        (ytm-radio--insert-detail-prefix detail-prefix prefix)
        (should (= (current-column) title-column)))))
  (with-temp-buffer
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _frame) t))
              ((symbol-function 'string-pixel-width)
               (lambda (string &optional _buffer)
                 (cond
                  ((equal string "wide") 40)
                  ((equal string "  ") 14)
                  (t 10)))))
      (ytm-radio--insert-detail-prefix "x" "wide")
      (should (equal (get-text-property (1+ (point-min)) 'display)
                     '(space :width (44)))))))

(ert-deftest ytm-radio-item-type-icon-renders-on-detail-line ()
  "Render the item type icon below the row number."
  (let ((source (ytm-radio--make-source
                 :id "search"
                 :kind 'youtube-music-search
                 :title "Search"))
        (item '((type . "album")
                (title . "Album")
                (artist . "Artist"))))
    (with-temp-buffer
      (cl-letf (((symbol-function 'ytm-radio--mdicon)
                 (lambda (_name _fallback) "I")))
        (ytm-radio--insert-source-item source item 1))
      (let ((lines (split-string (buffer-string) "\n" t)))
        (should (string-match-p "01[[:space:]]+Album" (car lines)))
        (should-not (string-match-p "I" (car lines)))
        (should (string-match-p "I[[:space:]]+Artist" (cadr lines)))))))

(ert-deftest ytm-radio-thumbnail-row-newline-is-gapless ()
  "Mark thumbnail row newlines so split covers do not show a gap."
  (with-temp-buffer
    (ytm-radio--insert-item-row-newline t)
    (should (eq (get-text-property (point-min) 'line-height) t)))
  (with-temp-buffer
    (ytm-radio--insert-item-row-newline nil)
    (should-not (get-text-property (point-min) 'line-height))))

(ert-deftest ytm-radio-thumbnail-height-follows-text-rows ()
  "Keep split thumbnail slices at least as tall as rendered text rows."
  (let ((ytm-radio-browser-thumbnail-size 48))
    (cl-letf (((symbol-function 'frame-char-height)
               (lambda (&optional _frame) 31)))
      (should (= (ytm-radio--browser-thumbnail-row-height) 31))
      (should (= (ytm-radio--browser-thumbnail-pixel-size) 62)))))

(ert-deftest ytm-radio-placeholder-thumbnail-renders-without-url ()
  "Render a fixed-canvas placeholder when an item has no thumbnail URL."
  (when (and (featurep 'svg)
             (image-type-available-p 'svg))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t)))
      (let ((thumbnail (ytm-radio--item-thumbnail-image
                        '((type . "album") (title . "Album")))))
        (should thumbnail)
        (should (eq (nth 3 thumbnail) 'fixed-canvas))))))

(ert-deftest ytm-radio-thumbnail-download-mutates-cached-image-state ()
  "Update the cached thumbnail image object without redrawing the browser."
  (let* ((url "https://example.invalid/thumb.jpg")
         (file "/tmp/thumb.jpg")
         (ytm-radio--browser-thumbnail-state-cache
          (make-hash-table :test #'equal))
         (ytm-radio--browser-thumbnail-state-keys-by-url
          (make-hash-table :test #'equal))
         (ytm-radio--browser-thumbnail-pending-urls nil)
         (state (ytm-radio--browser-thumbnail-state
                 url '((image :type svg :data "old") 48 62 fixed-canvas)))
         (image-object (car state))
         forced)
    (with-current-buffer (get-buffer-create ytm-radio--library-buffer-name)
      (cl-letf (((symbol-function 'file-readable-p)
                 (lambda (path) (equal path file)))
                ((symbol-function 'ytm-radio--thumbnail-image-from-file)
                 (lambda (_file)
                   '((image :type svg :data "new") 48 62 fixed-canvas)))
                ((symbol-function 'force-window-update)
                 (lambda (object) (setq forced object)))
                ((symbol-function 'ytm-radio--render-browser)
                 (lambda (&rest _) (error "rendered directly"))))
        (ytm-radio--thumbnail-download-finished url file)))
    (should (eq (car state) image-object))
    (should (equal (cdr image-object) '(:type svg :data "new")))
    (should (eq forced (get-buffer ytm-radio--library-buffer-name)))))

(ert-deftest ytm-radio-thumbnail-download-rerenders-unsupported-state ()
  "Redraw when a downloaded thumbnail cannot update the placeholder in place."
  (let* ((url "https://example.invalid/thumb.jpg")
         (file "/tmp/thumb.jpg")
         (ytm-radio--browser-thumbnail-state-cache
          (make-hash-table :test #'equal))
         (ytm-radio--browser-thumbnail-state-keys-by-url
          (make-hash-table :test #'equal))
         (ytm-radio--browser-thumbnail-pending-urls nil)
         (state (ytm-radio--browser-thumbnail-state
                 url '((image :type svg :data "old") 48 62 fixed-canvas)))
         rendered)
    (cl-letf (((symbol-function 'file-readable-p)
               (lambda (path) (equal path file)))
              ((symbol-function 'ytm-radio--thumbnail-image-from-file)
               (lambda (_file)
                 '((image :type jpeg) 24 18)))
              ((symbol-function 'force-window-update)
               (lambda (_object) (error "mutated unsupported state")))
              ((symbol-function 'ytm-radio--render-browser)
               (lambda (&rest _) (setq rendered t))))
      (ytm-radio--thumbnail-download-finished url file))
    (should state)
    (should rendered)))

(ert-deftest ytm-radio-thumbnail-downloads-respect-render-budget ()
  "Limit thumbnail downloads started during one browser render pass."
  (let ((ytm-radio--browser-thumbnail-download-budget 1)
        (ytm-radio--browser-thumbnail-pending-urls nil)
        (ytm-radio--cover-downloads (make-hash-table :test #'equal))
        requested)
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t))
              ((symbol-function 'ytm-radio--cover-file)
               (lambda (_url) nil))
              ((symbol-function 'ytm-radio--ensure-cover-file)
               (lambda (url _callback)
                 (push url requested)
                 nil))
              ((symbol-function 'ytm-radio--placeholder-thumbnail-image)
               (lambda (_item) nil)))
      (ytm-radio--item-thumbnail-image
       '((title . "Song A")
         (thumbnail-url . "https://example.invalid/a.jpg")))
      (ytm-radio--item-thumbnail-image
       '((title . "Song B")
         (thumbnail-url . "https://example.invalid/b.jpg")))
      (should (equal (nreverse requested)
                     '("https://example.invalid/a.jpg")))
      (should (equal ytm-radio--browser-thumbnail-pending-urls
                     '("https://example.invalid/b.jpg"))))))

(ert-deftest ytm-radio-thumbnail-download-registers-in-flight-callback ()
  "Attach thumbnail updates to cover downloads started by another surface."
  (let ((ytm-radio--browser-thumbnail-download-budget 1)
        (ytm-radio--browser-thumbnail-pending-urls nil)
        (ytm-radio--cover-downloads (make-hash-table :test #'equal))
        (url "https://example.invalid/a.jpg"))
    (ytm-radio--register-cover-download-callback url #'ignore)
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t))
              ((symbol-function 'ytm-radio--cover-file)
               (lambda (_url) nil))
              ((symbol-function 'ytm-radio--placeholder-thumbnail-image)
               (lambda (_item)
                 '((image :type svg :data "placeholder") 48 62 fixed-canvas)))
              ((symbol-function 'url-retrieve)
               (lambda (&rest _) (error "started duplicate download"))))
      (ytm-radio--item-thumbnail-image
       `((title . "Song A")
         (thumbnail-url . ,url))))
    (should (memq #'ytm-radio--thumbnail-download-finished
                  (ytm-radio--cover-download-callbacks url)))
    (should (memq #'ignore (ytm-radio--cover-download-callbacks url)))))

(ert-deftest ytm-radio-pending-thumbnail-downloads-respect-budget ()
  "Continue pending thumbnail downloads in bounded batches."
  (let ((ytm-radio-browser-thumbnail-downloads-per-render 1)
        (ytm-radio--browser-thumbnail-pending-urls
         '("https://example.invalid/a.jpg"
           "https://example.invalid/b.jpg"))
        (ytm-radio--cover-downloads (make-hash-table :test #'equal))
        requested)
    (cl-letf (((symbol-function 'ytm-radio--cover-file)
               (lambda (_url) nil))
              ((symbol-function 'ytm-radio--ensure-cover-file)
               (lambda (url _callback)
                 (push url requested)
                 nil)))
      (ytm-radio--start-pending-thumbnail-downloads)
      (should (equal (nreverse requested)
                     '("https://example.invalid/a.jpg")))
      (should (equal ytm-radio--browser-thumbnail-pending-urls
                     '("https://example.invalid/b.jpg"))))))

(ert-deftest ytm-radio-cover-download-keeps-multiple-callbacks ()
  "Allow several surfaces to observe one in-flight cover download."
  (let ((ytm-radio--cover-downloads (make-hash-table :test #'equal))
        calls)
    (ytm-radio--register-cover-download-callback
     "url" (lambda (_url _file) (push 'first calls)))
    (ytm-radio--register-cover-download-callback
     "url" (lambda (_url _file) (push 'second calls)))
    (cl-letf (((symbol-function 'file-readable-p) (lambda (_file) t)))
      (ytm-radio--run-cover-download-callbacks "url" "/tmp/cover.jpg"))
    (should (= (length calls) 2))
    (should (memq 'first calls))
    (should (memq 'second calls))
    (should-not (ytm-radio--cover-download-in-flight-p "url"))))

(ert-deftest ytm-radio-cover-download-failure-completes-callbacks ()
  "Complete cover callbacks even when no file was downloaded."
  (let ((ytm-radio--cover-downloads (make-hash-table :test #'equal))
        completed-file)
    (ytm-radio--register-cover-download-callback
     "url" (lambda (_url file) (setq completed-file (or file 'failed))))
    (cl-letf (((symbol-function 'file-readable-p) (lambda (_file) nil)))
      (ytm-radio--run-cover-download-callbacks "url" "/tmp/missing.jpg"))
    (should (eq completed-file 'failed))
    (should-not (ytm-radio--cover-download-in-flight-p "url"))))

(ert-deftest ytm-radio-cache-cover-coalesces-in-flight-requests ()
  "Register callbacks for one cover download without duplicate retrievals."
  (let ((ytm-radio--cover-downloads (make-hash-table :test #'equal))
        (url "https://example.invalid/cover.jpg")
        (callback-a (lambda (_url _file) nil))
        (callback-b (lambda (_url _file) nil))
        (retrieves 0))
    (cl-letf (((symbol-function 'ytm-radio--cover-cache-path)
               (lambda (_url) "/tmp/ytm-radio-cover.jpg"))
              ((symbol-function 'file-readable-p) (lambda (_file) nil))
              ((symbol-function 'make-directory) (lambda (&rest _) nil))
              ((symbol-function 'url-retrieve)
               (lambda (&rest _args)
                 (cl-incf retrieves)
                 'process)))
      (ytm-radio--cache-cover url callback-a)
      (ytm-radio--cache-cover url callback-b))
    (should (= retrieves 1))
    (should (memq callback-a (ytm-radio--cover-download-callbacks url)))
    (should (memq callback-b (ytm-radio--cover-download-callbacks url)))))

(ert-deftest ytm-radio-image-file-dimensions-uses-cache ()
  "Avoid measuring the same cached image file on every browser redraw."
  (let ((ytm-radio--image-dimensions-cache (make-hash-table :test #'equal))
        (file (make-temp-file "ytm-radio-dimensions-"))
        (calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'ytm-radio--image-file-dimensions-uncached)
                   (lambda (_file)
                     (cl-incf calls)
                     '(640 . 480))))
          (should (equal (ytm-radio--image-file-dimensions file) '(640 . 480)))
          (should (equal (ytm-radio--image-file-dimensions file) '(640 . 480)))
          (should (= calls 1)))
      (delete-file file))))

(ert-deftest ytm-radio-thumbnail-image-from-file-uses-cache ()
  "Avoid recreating thumbnail image objects on every browser redraw."
  (let ((ytm-radio--thumbnail-image-cache (make-hash-table :test #'equal))
        (file (make-temp-file "ytm-radio-thumbnail-"))
        (calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'ytm-radio--browser-thumbnail-display-size)
                   (lambda (_file) '(24 . 18)))
                  ((symbol-function 'ytm-radio--svg-thumbnail-image)
                   (lambda (_file) nil))
                  ((symbol-function 'create-image)
                   (lambda (&rest _args)
                     (cl-incf calls)
                     '(image :type jpeg))))
          (should (equal (ytm-radio--thumbnail-image-from-file file)
                         '((image :type jpeg) 24 18)))
          (should (equal (ytm-radio--thumbnail-image-from-file file)
                         '((image :type jpeg) 24 18)))
          (should (= calls 1)))
      (delete-file file))))

(ert-deftest ytm-radio-render-dashboard-limits-overview-items ()
  "Render overview sections with a compact item limit."
  (let* ((items (cl-loop for index from 1 to 10
                         collect `((type . "track")
                                   (id . ,(format "v%d" index))
                                   (title . ,(format "Song %d" index))
                                   (url . ,(format "https://music.youtube.com/watch?v=v%d"
                                                   index)))))
         (source (ytm-radio--make-source
                  :id "ytm:home:listen"
                  :kind 'youtube-music-home-section
                  :title "Listen again"
                  :url "https://music.youtube.com/"
                  :tracks nil
                  :items items))
         (ytm-radio--browser-view 'home)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render)
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p "Listen again" (buffer-string)))
      (should-not
       (string-match-p "youtube-music-home-section" (buffer-string)))
      (should-not
       (string-match-p "youtube-music-library" (buffer-string)))
      (should (string-match-p "2 more" (buffer-string)))
      (goto-char (point-min))
      (search-forward "10 items")
      (let ((newline (point)))
        (should (eq (char-after newline) ?\n))
        (should-not (get-text-property newline 'display))
        (should (equal (get-text-property (1+ newline) 'display)
                       '((height 0.25)))))
      (should-not (string-match-p "Home[[:space:]]+Explore"
                                  (buffer-string))))))

(ert-deftest ytm-radio-terminal-source-items-do-not-reserve-thumbnail-space ()
  "Keep terminal browser rows close to the left edge when images are unavailable."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:home:quick"
                  :kind 'youtube-music-home-section
                  :title "Quick picks"))
         (item '((type . "track")
                 (id . "v1")
                 (title . "Terminal Song")
                 (url . "https://music.youtube.com/watch?v=v1"))))
    (with-temp-buffer
      (cl-letf (((symbol-function 'display-graphic-p)
                 (lambda (&optional _frame) nil)))
        (ytm-radio--insert-source-item source item 1))
      (goto-char (point-min))
      (should (looking-at-p "01[[:space:]]+Terminal Song")))))

(ert-deftest ytm-radio-browser-navigation-uses-view-keys ()
  "Bind Home, Explore, and Library navigation to direct view keys."
  (should (eq (lookup-key ytm-radio--mode-map (kbd "H"))
              #'ytm-radio-home))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "E"))
              #'ytm-radio-explore))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "L"))
              #'ytm-radio-library))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "/"))
              #'ytm-radio-search))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "A"))
              #'ytm-radio-current-actions))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "b"))
              #'ytm-radio-back))
  (should-not (eq (lookup-key ytm-radio--mode-map (kbd "h"))
                  #'ytm-radio-home))
  (should-not (eq (lookup-key ytm-radio--mode-map (kbd "e"))
                  #'ytm-radio-explore))
  (should-not (lookup-key ytm-radio--mode-map (kbd "o")))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "l"))
              #'ytm-radio-like-current-track)))

(ert-deftest ytm-radio-source-summary-avoids-redundant-counts ()
  "Avoid showing duplicate item and track counts."
  (let* ((track-a (ytm-radio--make-track
                   :id "a"
                   :title "A"
                   :url "https://music.youtube.com/watch?v=a"))
         (track-b (ytm-radio--make-track
                   :id "b"
                   :title "B"
                   :url "https://music.youtube.com/watch?v=b"))
         (track-source (ytm-radio--make-source
                        :id "tracks"
                        :kind 'youtube-music-home-section
                        :title "Tracks"
                        :tracks (list track-a track-b)
                        :items (list track-a track-b)))
         (mixed-source (ytm-radio--make-source
                        :id "mixed"
                        :kind 'youtube-music-home-section
                        :title "Mixed"
                        :tracks (list track-a)
                        :items (list track-a '((type . "album")
                                               (title . "Album")))))
         (item-source (ytm-radio--make-source
                       :id "items"
                       :kind 'youtube-music-home-section
                       :title "Items"
                       :tracks nil
                       :items '(((type . "album") (title . "Album"))))))
    (should (equal (ytm-radio--source-summary track-source) "2 tracks"))
    (should (equal (ytm-radio--source-summary mixed-source)
                   "2 items / 1 track"))
    (should (equal (ytm-radio--source-summary item-source) "1 item"))))

(ert-deftest ytm-radio-more-opens-current-section-hidden-items ()
  "Open the full current section from any item row with `ytm-radio-more'."
  (let* ((items (cl-loop for index from 1 to 10
                         collect `((type . "track")
                                   (id . ,(format "v%d" index))
                                   (title . ,(format "Song %d" index))
                                   (url . ,(format "https://music.youtube.com/watch?v=v%d"
                                                   index)))))
         (source (ytm-radio--make-source
                  :id "ytm:home:listen"
                  :kind 'youtube-music-home-section
                  :title "Listen again"
                  :items items))
         (ytm-radio--browser-view 'home)
         (ytm-radio--browser-history nil)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render)
    (with-current-buffer "*ytm-radio*"
      (goto-char (point-min))
      (search-forward "Song 1")
      (ytm-radio-more)
      (should (eq (ytm-radio--view-kind) 'section))
      (should (equal (ytm-radio--view-value :source-id)
                     "ytm:home:listen")))))

(ert-deftest ytm-radio-render-browser-does-not-park-point-at-end ()
  "Keep browser point on content instead of leaving it at end after render."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:home:listen"
                  :kind 'youtube-music-home-section
                  :title "Listen again"
                  :url "https://music.youtube.com/"
                  :tracks nil
                  :items '(((type . "track")
                            (id . "v1")
                            (title . "Song")
                            (url . "https://music.youtube.com/watch?v=v1")))))
         (ytm-radio--browser-view 'home)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render)
    (with-current-buffer "*ytm-radio*"
      (goto-char (point-max))
      (ytm-radio--render-browser)
      (should-not (eobp))
      (should (ytm-radio--line-item-at-point)))))

(ert-deftest ytm-radio-render-now-playing-is-separate ()
  "Render now-playing content into its own buffer."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"
                :artist "Artist"
                :duration 185))
        (ytm-radio--player
         (ytm-radio--make-player :status 'playing
                                 :position 42
                                 :duration 185)))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render-now-playing)
    (with-current-buffer "*ytm-radio-now-playing*"
      (should (string-match-p "Song" (buffer-string)))
      (should (string-match-p "Artist" (buffer-string)))
      (should (string-match-p
               "0:42 ▰+▱+ 3:05"
               (buffer-string)))
      (should (string-match-p "<<" (buffer-string)))
      (should (string-match-p "||" (buffer-string)))
      (should (string-match-p ">>" (buffer-string)))
      (goto-char (point-min))
      (search-forward "||")
      (should (button-at (1- (point)))))))

(ert-deftest ytm-radio-render-now-playing-shows-rating-indicator ()
  "Render the current track rating marker after the title."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"
                :like-status 'dislike))
        (ytm-radio--player
         (ytm-radio--make-player :status 'playing)))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render-now-playing))
    (with-current-buffer "*ytm-radio-now-playing*"
      (should (string-match-p (regexp-quote "Song ▼")
                              (buffer-string))))))

(ert-deftest ytm-radio-now-playing-title-with-rating-fits-pixels ()
  "Keep now-playing title plus rating marker on one graphic line."
  (cl-letf (((symbol-function 'ytm-radio--now-playing-frame)
             (lambda () 'child))
            ((symbol-function 'display-graphic-p)
             (lambda (&optional _frame) t))
            ((symbol-function 'string-pixel-width)
             (lambda (string &optional _buffer)
               (cl-loop
                for char across (substring-no-properties (or string ""))
                sum (cond
                     ((eq char ?\s) 4)
                     ((eq char ?U) 18)
                     (t 12))))))
    (let ((text (ytm-radio--fit-title-with-rating-to-pixels
                 "ABCDE" " U" 'bold 50)))
      (should (string-suffix-p " U" (substring-no-properties text)))
      (should (<= (string-pixel-width text) 50)))))

(ert-deftest ytm-radio-side-window-renders-current-track ()
  "Render the current track in the side-window now-playing view."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"
                :artist "Artist"
                :duration 185))
        (ytm-radio--player
         (ytm-radio--make-player :status 'playing
                                 :position 42
                                 :duration 185)))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render-side-window))
    (with-current-buffer "*ytm-radio-now-playing*"
      (should (string-match-p "Song" (buffer-string)))
      (should (string-match-p "Artist" (buffer-string)))
      (should (string-match-p "0:42" (buffer-string)))
      (should (string-match-p (regexp-quote "<<") (buffer-string)))
      (should (string-match-p (regexp-quote ">>") (buffer-string)))
      (goto-char (point-min))
      (should (button-at (point)))
      (search-forward "Song")
      (should (button-at (match-beginning 0)))
      (search-forward "||")
      (should (button-at (1- (point)))))))

(defun ytm-radio-test--render-side-window-lines (width height)
  "Render side-window now-playing for WIDTH and HEIGHT, returning text lines."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"
                :artist "Artist"
                :duration 185))
        (ytm-radio-side-window-height height)
        (ytm-radio--player
         (ytm-radio--make-player :status 'playing
                                 :position 42
                                 :duration 185)))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback))
              ((symbol-function 'ytm-radio--side-window-content-width)
               (lambda () width)))
      (ytm-radio--render-side-window))
    (with-current-buffer "*ytm-radio-now-playing*"
      (mapcar #'string-trim-right
              (butlast (split-string
                        (buffer-substring-no-properties (point-min)
                                                        (point-max))
                        "\n"))))))

(ert-deftest ytm-radio-side-window-layout-is-single-line ()
  "Render side-window content on the first row only."
  (let ((lines (ytm-radio-test--render-side-window-lines 120 3)))
    (should (= (length lines) 3))
    (should (string-match-p "Song" (nth 0 lines)))
    (should (string-match-p "Artist" (nth 0 lines)))
    (should (string-match-p "0:42" (nth 0 lines)))
    (should (string-match-p (regexp-quote "||") (nth 0 lines)))
    (should (string-empty-p (nth 1 lines)))
    (should (string-empty-p (nth 2 lines)))))

(ert-deftest ytm-radio-side-window-layout-hides-controls-when-narrow ()
  "Hide side-window controls instead of wrapping when the frame is narrow."
  (let ((lines (ytm-radio-test--render-side-window-lines 40 3)))
    (should (= (length lines) 3))
    (should (string-match-p "Song" (nth 0 lines)))
    (should (string-match-p "0:42" (nth 0 lines)))
    (should (string-match-p "▰" (nth 0 lines)))
    (should-not (string-match-p (regexp-quote "||") (nth 0 lines)))
    (should (string-empty-p (nth 1 lines)))
    (should (string-empty-p (nth 2 lines)))))

(ert-deftest ytm-radio-side-window-style-uses-top-dedicated-window ()
  "Show the side-window display style in a top dedicated side window."
  (let ((ytm-radio-display-style 'side-window)
        (ytm-radio--side-window nil)
        (ytm-radio--player (ytm-radio--make-player))
        captured-action
        deleted-frame
        hidden-window
        restored-window)
    (cl-letf (((symbol-function 'ytm-radio--render-now-playing)
               #'ignore)
              ((symbol-function 'ytm-radio--render-side-window)
               #'ignore)
              ((symbol-function 'ytm-radio--delete-frame)
               (lambda () (setq deleted-frame t)))
              ((symbol-function 'ytm-radio--quit-buffer-window)
               (lambda (buffer-name)
                 (setq hidden-window buffer-name)))
              ((symbol-function 'display-buffer)
               (lambda (_buffer action)
                 (setq captured-action action)
                 'side-window))
              ((symbol-function 'selected-window)
               (lambda () 'normal-window))
              ((symbol-function 'select-window)
               (lambda (window &optional norecord)
                 (setq restored-window (list window norecord))))
              ((symbol-function 'set-window-dedicated-p)
               #'ignore)
              ((symbol-function 'delete-window)
               #'ignore)
              ((symbol-function 'set-window-fringes)
               #'ignore)
              ((symbol-function 'set-window-margins)
               #'ignore)
              ((symbol-function 'set-window-scroll-bars)
               #'ignore)
              ((symbol-function 'window-preserve-size)
               #'ignore)
              ((symbol-function 'window-live-p)
               (lambda (window) (memq window '(side-window normal-window))))
              ((symbol-function 'window-buffer)
               (lambda (_window) (get-buffer ytm-radio--now-playing-buffer-name))))
      (ytm-radio--show-now-playing)
      (should deleted-frame)
      (should (equal hidden-window ytm-radio--now-playing-buffer-name))
      (should (eq ytm-radio--side-window 'side-window))
      (should (equal (car captured-action) '(display-buffer-in-side-window)))
      (should (eq (alist-get 'side (cdr captured-action)) 'top))
      (should (= (alist-get 'slot (cdr captured-action)) -1))
      (should (eq (alist-get 'dedicated (cdr captured-action)) 'side))
      (should (eq (alist-get 'post-command-select-window
                             (cdr captured-action))
                  nil))
      (should (equal restored-window '(normal-window norecord)))
      (should (ytm-radio--now-playing-visible-p))
      (ytm-radio--hide-side-window))))

(ert-deftest ytm-radio-side-window-style-does-not-require-graphics ()
  "Use side-window now-playing in terminal frames."
  (let ((ytm-radio-display-style 'side-window)
        (ytm-radio--player (ytm-radio--make-player))
        captured-action
        child-frame-shown
        regular-buffer-shown)
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'ytm-radio--render-now-playing)
               #'ignore)
              ((symbol-function 'ytm-radio--render-side-window)
               #'ignore)
              ((symbol-function 'ytm-radio--delete-frame)
               #'ignore)
              ((symbol-function 'ytm-radio--quit-buffer-window)
               #'ignore)
              ((symbol-function 'ytm-radio--show-child-frame)
               (lambda (&rest _args) (setq child-frame-shown t)))
              ((symbol-function 'ytm-radio--show-regular-buffer)
               (lambda (&rest _args) (setq regular-buffer-shown t)))
              ((symbol-function 'display-buffer)
               (lambda (_buffer action)
                 (setq captured-action action)
                 'side-window))
              ((symbol-function 'selected-window)
               (lambda () 'normal-window))
              ((symbol-function 'select-window)
               #'ignore)
              ((symbol-function 'set-window-dedicated-p)
               #'ignore)
              ((symbol-function 'set-window-fringes)
               #'ignore)
              ((symbol-function 'set-window-margins)
               #'ignore)
              ((symbol-function 'set-window-scroll-bars)
               #'ignore)
              ((symbol-function 'window-preserve-size)
               #'ignore)
              ((symbol-function 'window-live-p)
               (lambda (window) (memq window '(side-window normal-window)))))
      (ytm-radio--show-now-playing)
      (should (equal (car captured-action) '(display-buffer-in-side-window)))
      (should-not child-frame-shown)
      (should-not regular-buffer-shown))))

(ert-deftest ytm-radio-side-window-mouse-events-do-not-select-window ()
  "Keep mouse clicks in the side-window now-playing buffer inert."
  (dolist (event '([mouse-1] [down-mouse-1] [drag-mouse-1]
                   [double-mouse-1] [triple-mouse-1]
                   [mouse-2] [down-mouse-2] [drag-mouse-2]
                   [double-mouse-2] [triple-mouse-2]
                   [mouse-3] [down-mouse-3] [drag-mouse-3]
                   [double-mouse-3] [triple-mouse-3]))
    (should (eq (lookup-key ytm-radio--now-playing-mode-map event)
                #'ignore))
    (should (eq (lookup-key ytm-radio--now-playing-inert-button-map event)
                #'ignore))))

(ert-deftest ytm-radio-side-window-non-controls-are-inert-buttons ()
  "Make the entire side-window surface clickable but inert."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"
                :artist "Artist"))
        (ytm-radio-side-window-height 2)
        (ytm-radio--player (ytm-radio--make-player :status 'playing)))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render-side-window))
    (with-current-buffer "*ytm-radio-now-playing*"
      (goto-char (point-min))
      (should (eq (button-get (button-at (point)) 'action) #'ignore))
      (search-forward "Song")
      (should (eq (button-get (button-at (match-beginning 0)) 'action)
                  #'ignore))
      (forward-line 1)
      (should (eq (button-get (button-at (point)) 'action) #'ignore)))))

(ert-deftest ytm-radio-side-window-preserves-progress-filled-face ()
  "Keep the side-window progress fill face distinct from shadow text."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"
                :artist "Artist"
                :duration 208))
        (ytm-radio-side-window-height 1)
        (ytm-radio--player
         (ytm-radio--make-player :status 'playing
                                 :position 53
                                 :duration 208)))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (ytm-radio--render-side-window))
    (with-current-buffer "*ytm-radio-now-playing*"
      (goto-char (point-min))
      (search-forward "0:53")
      (let ((face (get-text-property (match-beginning 0) 'face)))
        (should-not (if (listp face)
                        (memq 'shadow face)
                      (eq face 'shadow))))
      (search-forward "▰")
      (let ((face (get-text-property (1- (point)) 'face)))
        (should (if (listp face)
                    (memq 'ytm-radio-progress-filled face)
                  (eq face 'ytm-radio-progress-filled)))))))

(ert-deftest ytm-radio-child-frame-supported-p-detects-tty-feature ()
  "Use TTY child frames only when Emacs reports support for them."
  (cl-letf (((symbol-function 'display-graphic-p)
             (lambda (&optional _frame) nil))
            ((symbol-function 'featurep)
             (lambda (feature &optional _subfeature)
               (eq feature 'tty-child-frames))))
    (should (ytm-radio--child-frame-supported-p)))
  (cl-letf (((symbol-function 'display-graphic-p)
             (lambda (&optional _frame) nil))
            ((symbol-function 'featurep)
             (lambda (&rest _args) nil)))
    (should-not (ytm-radio--child-frame-supported-p)))
  (cl-letf (((symbol-function 'display-graphic-p)
             (lambda (&optional _frame) t))
            ((symbol-function 'featurep)
             (lambda (&rest _args) nil)))
    (should (ytm-radio--child-frame-supported-p))))

(ert-deftest ytm-radio-child-frame-style-uses-tty-child-frame-when-supported ()
  "Show child-frame now-playing in terminal frames with TTY child-frame support."
  (let ((ytm-radio-display-style 'child-frame)
        (ytm-radio--player (ytm-radio--make-player))
        child-frame-shown
        regular-buffer-shown)
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'featurep)
               (lambda (feature &optional _subfeature)
                 (eq feature 'tty-child-frames)))
              ((symbol-function 'ytm-radio--render-now-playing)
               #'ignore)
              ((symbol-function 'ytm-radio--hide-side-window)
               #'ignore)
              ((symbol-function 'ytm-radio--show-child-frame)
               (lambda (_buffer focus)
                 (setq child-frame-shown focus)))
              ((symbol-function 'ytm-radio--show-regular-buffer)
               (lambda (&rest _args) (setq regular-buffer-shown t))))
      (ytm-radio--show-now-playing t)
      (should child-frame-shown)
      (should-not regular-buffer-shown))))

(ert-deftest ytm-radio-child-frame-style-falls-back-without-tty-support ()
  "Use a regular buffer when terminal child frames are unavailable."
  (let ((ytm-radio-display-style 'child-frame)
        (ytm-radio--player (ytm-radio--make-player))
        child-frame-shown
        regular-buffer-shown)
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'featurep)
               (lambda (&rest _args) nil))
              ((symbol-function 'ytm-radio--render-now-playing)
               #'ignore)
              ((symbol-function 'ytm-radio--hide-side-window)
               #'ignore)
              ((symbol-function 'ytm-radio--show-child-frame)
               (lambda (&rest _args) (setq child-frame-shown t)))
              ((symbol-function 'ytm-radio--show-regular-buffer)
               (lambda (&rest _args) (setq regular-buffer-shown t))))
      (ytm-radio--show-now-playing)
      (should regular-buffer-shown)
      (should-not child-frame-shown))))

(ert-deftest ytm-radio-child-frame-style-falls-back-after-frame-error ()
  "Use a regular buffer if child-frame creation fails at display time."
  (let ((ytm-radio-display-style 'child-frame)
        (ytm-radio--player (ytm-radio--make-player))
        regular-buffer-shown
        message-text)
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'featurep)
               (lambda (feature &optional _subfeature)
                 (eq feature 'tty-child-frames)))
              ((symbol-function 'ytm-radio--render-now-playing)
               #'ignore)
              ((symbol-function 'ytm-radio--hide-side-window)
               #'ignore)
              ((symbol-function 'ytm-radio--show-child-frame)
               (lambda (&rest _args)
                 (error "terminal rejected child frame")))
              ((symbol-function 'ytm-radio--show-regular-buffer)
               (lambda (&rest _args) (setq regular-buffer-shown t)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (ytm-radio--show-now-playing)
      (should regular-buffer-shown)
      (should (string-match-p "using buffer" message-text)))))

(ert-deftest ytm-radio-playback-status-does-not-rerender-browser ()
  "Keep browser content stable when mpv reports play/pause status changes."
  (let ((ytm-radio--player (ytm-radio--make-player :status 'playing))
        (browser-rendered nil)
        (now-playing-rendered nil))
    (cl-letf (((symbol-function 'ytm-radio--render-browser)
               (lambda (&optional _reset-point _history-entry)
                 (setq browser-rendered t)))
              ((symbol-function 'ytm-radio--render-now-playing-without-fit)
               (lambda ()
                 (setq now-playing-rendered t))))
      (ytm-radio--mpv-event
       "property-change"
       '((name . "pause") (data . t)))
      (should (eq (map-elt ytm-radio--player :status) 'paused))
      (should now-playing-rendered)
      (should-not browser-rendered))))

(ert-deftest ytm-radio-mpv-filter-handles-multiple-json-lines ()
  "Parse multiple mpv JSON lines from one process filter chunk."
  (let* ((process (make-process
                   :name "ytm-radio-test-filter"
                   :buffer nil
                   :command '("true")
                   :noquery t))
         (ytm-radio--player
          (ytm-radio--make-player :status 'idle :ipc-process process)))
    (unwind-protect
        (cl-letf (((symbol-function 'ytm-radio--render-now-playing-without-fit)
                   #'ignore))
          (ytm-radio--mpv-filter
           process
           (concat
            "{\"event\":\"property-change\",\"id\":4,\"name\":\"duration\"}\n"
            "{\"event\":\"property-change\",\"id\":4,\"name\":\"duration\",\"data\":208.381000}\n"
            "{\"event\":\"property-change\",\"id\":2,\"name\":\"core-idle\",\"data\":false}\n"))
          (should (= (map-elt ytm-radio--player :duration) 208.381000))
          (should (eq (map-elt ytm-radio--player :status) 'playing))
          (should (equal (process-get process 'pending) "")))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest ytm-radio-mpv-dispatch-ignores-stale-ipc-process ()
  "Ignore mpv events delivered by an older IPC process."
  (let ((ytm-radio--player
         (ytm-radio--make-player :status 'idle :ipc-process 'current)))
    (ytm-radio--mpv-dispatch
     'stale
     "{\"event\":\"property-change\",\"name\":\"core-idle\",\"data\":false}")
    (should (eq (map-elt ytm-radio--player :status) 'idle))
    (cl-letf (((symbol-function 'ytm-radio--render-now-playing-without-fit)
               #'ignore))
      (ytm-radio--mpv-dispatch
       'current
       "{\"event\":\"property-change\",\"name\":\"core-idle\",\"data\":false}"))
    (should (eq (map-elt ytm-radio--player :status) 'playing))))

(ert-deftest ytm-radio-now-playing-controls-include-playback-modes ()
  "Render repeat and shuffle in the compact now-playing controls."
  (let ((ytm-radio--player
         (ytm-radio--make-player :status 'playing
                                 :repeat 'all
                                 :shuffle t)))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (should (equal (mapcar #'car (ytm-radio--now-playing-controls))
                     '("R" "<<" "||" ">>" "S")))
      (should-not (member "^" (mapcar #'car (ytm-radio--now-playing-controls))))
      (should (string-match-p "R  <<  ||  >>  S"
                              (ytm-radio--now-playing-controls-text))))))

(ert-deftest ytm-radio-now-playing-controls-use-repeat-and-shuffle-icons ()
  "Use YouTube Music-style repeat and shuffle state icons."
  (let (requested-icons)
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (name fallback)
                 (push name requested-icons)
                 fallback)))
      (let* ((ytm-radio--player (ytm-radio--make-player))
             (repeat (ytm-radio--repeat-control))
             (shuffle (ytm-radio--shuffle-control)))
        (should (equal (nth 2 repeat) "Repeat off"))
        (should (eq (nth 3 repeat) 'shadow))
        (should (equal (nth 2 shuffle) "Shuffle off"))
        (should (eq (nth 3 shuffle) 'shadow))
        (should (member "nf-md-repeat" requested-icons))
        (should (member "nf-md-shuffle_variant" requested-icons)))
      (setq requested-icons nil)
      (let* ((ytm-radio--player (ytm-radio--make-player
                                 :repeat 'all
                                 :shuffle t))
             (repeat (ytm-radio--repeat-control))
             (shuffle (ytm-radio--shuffle-control)))
        (should (equal (nth 2 repeat) "Repeat all"))
        (should (eq (nth 3 repeat) 'bold))
        (should (equal (nth 2 shuffle) "Shuffle on"))
        (should (eq (nth 3 shuffle) 'bold))
        (should (member "nf-md-repeat" requested-icons))
        (should (member "nf-md-shuffle_variant" requested-icons)))
      (setq requested-icons nil)
      (let* ((ytm-radio--player (ytm-radio--make-player :repeat 'one))
             (repeat (ytm-radio--repeat-control)))
        (should (equal (nth 2 repeat) "Repeat one"))
        (should (eq (nth 3 repeat) 'bold))
        (should (member "nf-md-repeat_once" requested-icons))))))

(ert-deftest ytm-radio-now-playing-controls-use-pixel-centering ()
  "Center compact now-playing controls by pixel width on graphic frames."
  (let ((ytm-radio--player
         (ytm-radio--make-player :status 'playing)))
    (with-temp-buffer
      (cl-letf (((symbol-function 'display-graphic-p)
                 (lambda (&optional _frame) t))
                ((symbol-function 'ytm-radio--now-playing-text-pixel-width)
                 (lambda () 100))
                ((symbol-function 'ytm-radio--mdicon)
                 (lambda (_name fallback) fallback))
                ((symbol-function 'string-pixel-width)
                 (lambda (_string &optional _buffer) 40)))
        (ytm-radio--insert-now-playing-controls)
        (should (equal (get-text-property (point-min) 'display)
                       '(space :width (30))))))))

(ert-deftest ytm-radio-now-playing-cover-uses-visual-padding ()
  "Place the cover with the tuned child-frame visual padding."
  (with-temp-buffer
    (cl-letf (((symbol-function 'ytm-radio--now-playing-frame)
               (lambda () 'child))
              ((symbol-function 'frame-char-width)
               (lambda (&optional _frame) 10))
              ((symbol-function 'ytm-radio--now-playing-controls-text)
               (lambda () ""))
              ((symbol-function 'insert-image)
               (lambda (&rest _arguments) (insert "image"))))
      (should (ytm-radio--insert-cover '(image (180 . 180))))
      (goto-char (point-min))
      (forward-char 1)
      (should (equal (get-text-property (point) 'display)
                     '(space :width (7)))))))

(ert-deftest ytm-radio-terminal-now-playing-cover-omits-placeholder ()
  "Do not show a textual cover placeholder in terminal child-frame rendering."
  (with-temp-buffer
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil)))
      (should-not (ytm-radio--insert-cover nil))
      (should (string-empty-p (buffer-string))))))

(ert-deftest ytm-radio-now-playing-fit-frame-follows-cover-width ()
  "Size the now-playing child frame from the current cover width."
  (let (recorded-widths recorded-pixelwise image-width)
    (with-temp-buffer
      (cl-letf (((symbol-function 'ytm-radio--buffer-image)
                 (lambda (_buffer) 'image))
                ((symbol-function 'image-size)
                 (lambda (&rest _arguments) (cons image-width 180)))
                ((symbol-function 'ytm-radio--now-playing-frame-height)
                 (lambda (&rest _arguments) 240))
                ((symbol-function 'set-frame-width)
                 (lambda (_frame width &optional _pretend pixelwise-arg)
                   (push width recorded-widths)
                   (setq recorded-pixelwise pixelwise-arg)))
                ((symbol-function 'set-frame-height)
                 (lambda (&rest _arguments) nil))
                ((symbol-function 'frame-char-width)
                 (lambda (&optional _frame) 10))
                ((symbol-function 'ytm-radio--now-playing-controls-text)
                 (lambda () "")))
        (setq image-width 180)
        (ytm-radio--fit-frame 'child (current-buffer))
        (setq image-width 160)
        (ytm-radio--fit-frame 'child (current-buffer))))
    (should (equal (nreverse recorded-widths) '(192 172)))
    (should recorded-pixelwise)))

(ert-deftest ytm-radio-now-playing-safe-text-width-keeps-extra-column ()
  "Use the progress-line margin plus one extra column for title text."
  (let ((ytm-radio--progress-line-safety-columns 2))
    (cl-letf (((symbol-function 'ytm-radio--now-playing-text-width)
               (lambda () 20)))
      (should (= (ytm-radio--now-playing-safe-text-width) 17)))))

(ert-deftest ytm-radio-marquee-text-scrolls-long-title ()
  "Render long titles as fixed-width marquee slices."
  (let ((title "abcdefghij"))
    (should (equal (ytm-radio--marquee-text title 5 0) "abcde"))
    (should (equal (ytm-radio--marquee-text title 5 2) "cdefg"))
    (should (= (string-width (ytm-radio--marquee-text title 5 7)) 5))
    (should (equal (ytm-radio--marquee-text "short" 8 3) "short"))))

(defun ytm-radio-test--render-now-playing-with-cover ()
  "Render now-playing with a deterministic cover image placeholder."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"))
        (ytm-radio-display-style 'buffer)
        (ytm-radio--player (ytm-radio--make-player)))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--cover-spec)
               (lambda (_track) '(image (180 . 180))))
              ((symbol-function 'ytm-radio--now-playing-frame)
               (lambda () 'child))
              ((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'frame-char-width)
               (lambda (&optional _frame) 10))
              ((symbol-function 'ytm-radio--now-playing-controls-text)
               (lambda () ""))
              ((symbol-function 'insert-image)
               (lambda (&rest _arguments) (insert "image")))
              ((symbol-function 'ytm-radio--now-playing-visible-p)
               (lambda () nil)))
      (ytm-radio--render-now-playing))))

(ert-deftest ytm-radio-render-now-playing-gaps-cover-and-title ()
  "Insert thin padding between the cover and title."
  (ytm-radio-test--render-now-playing-with-cover)
  (with-current-buffer "*ytm-radio-now-playing*"
    (goto-char (point-min))
    (search-forward "image\n")
    (should (equal (get-text-property (point) 'display)
                   '((height 0.25))))))

(ert-deftest ytm-radio-render-now-playing-omits-terminal-cover-placeholder ()
  "Render terminal child-frame content without a fake cover marker."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"))
        (ytm-radio--player (ytm-radio--make-player))
        (ytm-radio-display-style 'child-frame))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--cover-spec)
               (lambda (_track) nil))
              ((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'featurep)
               (lambda (feature &optional _subfeature)
                 (eq feature 'tty-child-frames)))
              ((symbol-function 'ytm-radio--now-playing-visible-p)
               (lambda () nil)))
      (ytm-radio--render-now-playing))
    (with-current-buffer "*ytm-radio-now-playing*"
      (goto-char (point-min))
      (should-not (looking-at-p "\\+[-]+\\+"))
      (should (string-match-p "Song" (buffer-string)))
      (should-not (string-match-p (regexp-quote "[cover]")
                                  (buffer-string))))))

(ert-deftest ytm-radio-render-now-playing-uses-larger-edge-padding ()
  "Give now-playing top and bottom edges a little more padding."
  (ytm-radio-test--render-now-playing-with-cover)
  (with-current-buffer "*ytm-radio-now-playing*"
    (goto-char (point-min))
    (should (equal (get-text-property (point) 'display)
                   '((height 0.5))))
    (goto-char (point-max))
    (forward-line -1)
    (should (equal (get-text-property (point) 'display)
                   '((height 0.5))))))

(ert-deftest ytm-radio-now-playing-frame-height-uses-measured-content ()
  "Do not add implicit bottom padding to the measured child-frame height."
  (with-temp-buffer
    (insert "content")
    (cl-letf (((symbol-function 'frame-root-window)
               (lambda (_frame) 'window))
              ((symbol-function 'window-text-pixel-size)
               (lambda (_window _from _to _x-limit _y-limit)
                 '(80 . 120)))
              ((symbol-function 'frame-char-height)
               (lambda (_frame) 17)))
      (should (= (ytm-radio--now-playing-frame-height
                  'frame (current-buffer) 'image)
                 120)))))

(ert-deftest ytm-radio-key-bindings-include-current-actions ()
  "Expose transient actions only from the browser buffer."
  (should (eq (lookup-key ytm-radio--mode-map (kbd "q"))
              #'ytm-radio-hide-browser))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "A"))
              #'ytm-radio-current-actions))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "l"))
              #'ytm-radio-like-current-track))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "d"))
              #'ytm-radio-dislike-current-track))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "R"))
              #'ytm-radio-start-current-track-mix))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "P"))
              #'ytm-radio-add-current-track-to-playlist))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "t"))
              #'ytm-radio-toggle-current-track-library))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "Q"))
              #'ytm-radio-queue))
  (should (eq (lookup-key ytm-radio--now-playing-mode-map (kbd "q"))
              #'ytm-radio-hide-now-playing))
  (should-not (lookup-key ytm-radio--now-playing-mode-map (kbd "A")))
  (should (eq (lookup-key ytm-radio--now-playing-mode-map (kbd "l"))
              #'ytm-radio-like-current-track))
  (should (eq (lookup-key ytm-radio--now-playing-mode-map (kbd "d"))
              #'ytm-radio-dislike-current-track))
  (should (eq (lookup-key ytm-radio--now-playing-mode-map (kbd "R"))
              #'ytm-radio-start-current-track-mix))
  (should (eq (lookup-key ytm-radio--now-playing-mode-map (kbd "P"))
              #'ytm-radio-add-current-track-to-playlist))
  (should (eq (lookup-key ytm-radio--now-playing-mode-map (kbd "t"))
              #'ytm-radio-toggle-current-track-library))
  (should (eq (lookup-key ytm-radio--now-playing-mode-map (kbd "Q"))
              #'ytm-radio-queue)))

(ert-deftest ytm-radio-ui-modes-truncate-lines ()
  "Disable visual wrapping in ytm-radio UI buffers."
  (with-temp-buffer
    (setq-local truncate-lines nil)
    (setq-local word-wrap t)
    (ytm-radio--mode)
    (should truncate-lines)
    (should-not word-wrap))
  (with-temp-buffer
    (setq-local truncate-lines nil)
    (setq-local word-wrap t)
    (ytm-radio--now-playing-mode)
    (should truncate-lines)
    (should-not word-wrap)))

(ert-deftest ytm-radio-ui-buffer-access-reapplies-truncation ()
  "Keep ytm-radio UI buffers non-wrapping after later local changes."
  (let ((ytm-radio--library-buffer-name " *ytm-radio-test-browser*")
        (ytm-radio--now-playing-buffer-name " *ytm-radio-test-now-playing*"))
    (unwind-protect
        (progn
          (with-current-buffer (ytm-radio--buffer)
            (setq-local truncate-lines nil)
            (setq-local word-wrap t))
          (with-current-buffer (ytm-radio--buffer)
            (should truncate-lines)
            (should-not word-wrap))
          (with-current-buffer (ytm-radio--now-playing-buffer)
            (setq-local truncate-lines nil)
            (setq-local word-wrap t))
          (with-current-buffer (ytm-radio--now-playing-buffer)
            (should truncate-lines)
            (should-not word-wrap)))
      (when (get-buffer ytm-radio--library-buffer-name)
        (kill-buffer ytm-radio--library-buffer-name))
      (when (get-buffer ytm-radio--now-playing-buffer-name)
        (kill-buffer ytm-radio--now-playing-buffer-name)))))

(ert-deftest ytm-radio-repeat-and-shuffle-commands-update-player ()
  "Toggle repeat and shuffle playback modes."
  (let ((ytm-radio--player (ytm-radio--make-player)))
    (cl-letf (((symbol-function 'ytm-radio--render-now-playing) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-cycle-repeat)
      (should (eq (map-elt ytm-radio--player :repeat) 'all))
      (ytm-radio-cycle-repeat)
      (should (eq (map-elt ytm-radio--player :repeat) 'one))
      (ytm-radio-cycle-repeat)
      (should-not (map-elt ytm-radio--player :repeat))
      (ytm-radio-toggle-shuffle)
      (should (map-elt ytm-radio--player :shuffle))
      (ytm-radio-toggle-shuffle)
      (should-not (map-elt ytm-radio--player :shuffle)))))

(ert-deftest ytm-radio-track-video-id-requires-youtube-video-id ()
  "Only expose valid YouTube video ids to account actions."
  (should (equal (ytm-radio--track-video-id-from-url
                  "https://music.youtube.com/watch?v=abc123_DEF4")
                 "abc123_DEF4"))
  (should (equal (ytm-radio--track-video-id-from-url
                  "https://youtu.be/abc123_DEF4")
                 "abc123_DEF4"))
  (should-not (ytm-radio--track-video-id-from-url
               "https://notyoutube.com/watch?v=abc123_DEF4"))
  (should-not (ytm-radio--track-video-id
               (ytm-radio--make-track
                :id "local-id"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1")))
  (should (equal (ytm-radio--track-video-id
                  (ytm-radio--make-track
                   :id "abc123_DEF4"
                   :title "Imported"
                   :url "https://example.com/audio"))
                 "abc123_DEF4")))

(ert-deftest ytm-radio-like-current-track-rates-through-helper ()
  "Rate the current track through the account helper and cache local status."
  (let* ((track (ytm-radio--make-track
                 :id "local-id"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=abc123_DEF4"))
         (ytm-radio--player (ytm-radio--make-player :current-track track))
         (ytm-radio-helper-auth-file nil)
         called-arguments)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success
                          '((video-id . "abc123_DEF4") (rating . "like")))))
              ((symbol-function 'ytm-radio--render-now-playing) #'ignore)
              ((symbol-function 'ytm-radio--render-browser) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-like-current-track)
      (should (equal called-arguments '("rate" "abc123_DEF4" "like")))
      (should (eq (ytm-radio--track-like-status track) 'like))
      (ytm-radio-like-current-track)
      (should (equal called-arguments '("rate" "abc123_DEF4" "indifferent")))
      (should-not (ytm-radio--track-like-status track)))))

(ert-deftest ytm-radio-like-current-track-uses-cached-like-status ()
  "Unlike a current track whose rating is known from cached sources."
  (let* ((track (ytm-radio--make-track
                 :id "local-id"
                 :title "bonus funk"
                 :url "https://music.youtube.com/watch?v=2KoWN3sAFms"))
         (library-track (ytm-radio--make-track
                         :id "2KoWN3sAFms"
                         :title "bonus funk"
                         :url "https://music.youtube.com/watch?v=2KoWN3sAFms"
                         :like-status 'like))
         (source (ytm-radio--make-source
                  :id "ytm:library:songs"
                  :kind 'youtube-music-library-section
                  :title "Library Songs"
                  :tracks (list library-track)
                  :items nil))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player :current-track track))
         (ytm-radio-helper-auth-file nil)
         called-arguments)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success
                          '((video-id . "2KoWN3sAFms")
                            (rating . "indifferent")))))
              ((symbol-function 'ytm-radio--render-now-playing) #'ignore)
              ((symbol-function 'ytm-radio--render-browser) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-like-current-track)
      (should (equal called-arguments
                     '("rate" "2KoWN3sAFms" "indifferent")))
      (should-not (ytm-radio--track-like-status track))
      (should (eq (map-elt library-track :like-status) 'like)))))

(ert-deftest ytm-radio-current-actions-labels-follow-track-state ()
  "Use action labels for current-track transient suffixes."
  (let* ((track (ytm-radio--make-track
                 :id "abc123_DEF4"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=abc123_DEF4"))
         (ytm-radio--player (ytm-radio--make-player :current-track track)))
    (should (string-equal (ytm-radio--current-like-action-label) "Like"))
    (should (string-equal (ytm-radio--current-dislike-action-label) "Dislike"))
    (should (string-equal (ytm-radio--current-track-library-action-label)
                          "Save to library"))
    (setf (map-elt track :like-status) 'like)
    (should (string-equal (ytm-radio--current-like-action-label) "Unlike"))
    (should (string-equal (ytm-radio--current-dislike-action-label) "Dislike"))
    (setf (map-elt track :like-status) 'dislike)
    (should (string-equal (ytm-radio--current-like-action-label) "Like"))
    (should (string-equal (ytm-radio--current-dislike-action-label)
                          "Remove dislike"))
    (setf (map-elt track :in-library) t)
    (should (string-equal (ytm-radio--current-track-library-action-label)
                          "Remove from library"))))

(ert-deftest ytm-radio-set-track-like-status-indexes-source-items ()
  "Expose local rating changes without mutating cached source payloads."
  (let* ((item '((type . "track")
                 (id . "abc123_DEF4")
                 (title . "Song")
                 (url . "https://music.youtube.com/watch?v=abc123_DEF4")))
         (track (ytm-radio--track-from-helper-item
                 item "ytm:home:listen" 'youtube-music-home))
         (source-track (copy-tree track))
         (source (ytm-radio--make-source
                  :id "ytm:home:listen"
                  :kind 'youtube-music-home-section
                  :title "Listen again"
                  :tracks (list source-track)
                  :items (list item)))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player
          (ytm-radio--make-player :current-track track))
         (browser-rendered nil)
         (now-playing-rendered nil))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--render-now-playing)
               (lambda () (setq now-playing-rendered t)))
              ((symbol-function 'ytm-radio--render-browser)
               (lambda (&rest _args) (setq browser-rendered t))))
      (ytm-radio--set-track-like-status track 'like)
      (should (eq (ytm-radio--track-like-status track) 'like))
      (should (eq (ytm-radio--track-like-status source-track) 'like))
      (should (eq (ytm-radio--track-like-status item) 'like))
      (should-not (map-elt track :like-status))
      (should-not (map-elt source-track :like-status))
      (should-not (assq 'like-status item))
      (should now-playing-rendered)
      (should browser-rendered)
      (ytm-radio--set-track-like-status track nil)
      (should-not (ytm-radio--track-like-status track))
      (should-not (ytm-radio--track-like-status source-track))
      (should-not (ytm-radio--track-like-status item)))))

(ert-deftest ytm-radio-refresh-track-status-applies-helper-data ()
  "Refresh current track account status through the helper without prompting."
  (let* ((track (ytm-radio--make-track
                 :id "local-id"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=abc123_DEF4"))
         (ytm-radio--track-status-refreshes (make-hash-table :test #'equal))
         (ytm-radio--player (ytm-radio--make-player :current-track track))
         (ytm-radio-helper-auth-file nil)
         called-arguments
         (call-count 0)
         now-playing-rendered)
    (cl-letf (((symbol-function 'ytm-radio--track-status-refresh-available-p)
               (lambda () t))
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (cl-incf call-count)
                 (setq called-arguments arguments)
                 (funcall success '((video-id . "abc123_DEF4")
                                    (in-library . t)
                                    (like-status . "like")))))
              ((symbol-function 'ytm-radio--render-now-playing)
               (lambda () (setq now-playing-rendered t)))
              ((symbol-function 'ytm-radio--render-browser) #'ignore))
      (ytm-radio--refresh-track-status track)
      (should (equal called-arguments '("track-status" "abc123_DEF4")))
      (should (eq (ytm-radio--track-like-status track) 'like))
      (should (ytm-radio--track-library-status-p track))
      (should now-playing-rendered)
      (should (numberp (gethash "abc123_DEF4"
                                ytm-radio--track-status-refreshes)))
      (ytm-radio--refresh-track-status track)
      (should (= call-count 1))
      (puthash "abc123_DEF4"
               (- (float-time) ytm-radio--track-status-refresh-ttl 1)
               ytm-radio--track-status-refreshes)
      (ytm-radio--refresh-track-status track)
      (should (= call-count 2)))))

(ert-deftest ytm-radio-apply-track-status-preserves-unknown-like-status ()
  "Preserve cached ratings when helper track status omits like-status."
  (let* ((track (ytm-radio--make-track
                 :id "home-row"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=abc123_DEF4"))
         (library-track (ytm-radio--make-track
                         :id "library-row"
                         :title "Song"
                         :url "https://music.youtube.com/watch?v=abc123_DEF4"
                         :like-status 'like))
         (source (ytm-radio--make-source
                  :id "ytm:library:songs"
                  :kind 'youtube-music-library-songs
                  :title "Songs"
                  :tracks (list library-track)))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player
          (ytm-radio--make-player :current-track track))
         now-playing-rendered)
    (cl-letf (((symbol-function 'ytm-radio--render-now-playing)
               (lambda () (setq now-playing-rendered t)))
              ((symbol-function 'ytm-radio--render-browser) #'ignore))
      (should (eq (ytm-radio--track-like-status track) 'like))
      (ytm-radio--apply-track-status
       track
       '((video-id . "abc123_DEF4")
         (in-library . t)))
      (should (eq (ytm-radio--track-like-status track) 'like))
      (should (eq (map-elt library-track :like-status) 'like))
      (should (ytm-radio--track-library-status-p track))
      (should now-playing-rendered)
      (ytm-radio--apply-track-status
       track
       '((video-id . "abc123_DEF4")
         (like-status . nil)))
      (should-not (ytm-radio--track-like-status track))
      (should (eq (map-elt library-track :like-status) 'like)))))

(ert-deftest ytm-radio-toggle-current-track-library-calls-helper ()
  "Toggle library status for the current track through the helper."
  (let* ((track (ytm-radio--make-track
                 :id "local-id"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=abc123_DEF4"))
         (ytm-radio--player (ytm-radio--make-player :current-track track))
         (ytm-radio-helper-auth-file nil)
         called-arguments)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success '((video-id . "abc123_DEF4")
                                    (in-library . t)
                                    (like-status . "like")
                                    (changed . t)))))
              ((symbol-function 'ytm-radio--render-now-playing) #'ignore)
              ((symbol-function 'ytm-radio--render-browser) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-toggle-current-track-library)
      (should (equal called-arguments '("library" "abc123_DEF4" "toggle")))
      (should (ytm-radio--track-library-status-p track))
      (should (eq (ytm-radio--track-like-status track) 'like)))))

(ert-deftest ytm-radio-toggle-detail-library-applies-refreshed-source ()
  "Toggle detail library status and replace the current detail from helper data."
  (let* ((item '((type . "playlist")
                 (id . "PL1")
                 (title . "Playlist")
                 (playlist-id . "PL1")
                 (browse-id . "VLPL1")))
         (detail-source (ytm-radio--make-source
                         :id "ytm:browse:VLPL1:header"
                         :kind 'youtube-music-playlist
                         :title "Focus Mix"
                         :url "https://music.youtube.com/browse/VLPL1"))
         (home-source (ytm-radio--make-source
                       :id "ytm:home:playlists"
                       :kind 'youtube-music-home-section
                       :title "Playlists"
                       :items (list item)))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt detail-source :id)))
                (cons :browse-id "VLPL1")
                (cons :browse-params "ggMCCAI%3D")))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt detail-source :id) detail-source)
                          (cons (map-elt home-source :id) home-source))))
         (ytm-radio-helper-auth-file nil)
         called-arguments
         rendered)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success
                          (ytm-radio-test--detail-helper-data
                           "VLPL1" "youtube-music-playlist" "Focus Mix"
                           '(in-library . t)))))
              ((symbol-function 'ytm-radio--render-browser)
               (lambda (&rest _args) (setq rendered t)))
              ((symbol-function 'message) #'ignore))
      (ytm-radio-toggle-detail-library)
      (should (equal called-arguments
                     '("item-library" "VLPL1" "save"
                       "--params" "ggMCCAI%3D")))
      (should (map-elt (ytm-radio--source "ytm:browse:VLPL1:header")
                       :in-library))
      (should (ytm-radio--truthy-field-p item :in-library))
      (should-not (assq 'in-library item))
      (should rendered))))

(ert-deftest ytm-radio-toggle-detail-library-removes-saved-source ()
  "Remove a saved detail source from the YouTube Music library."
  (let* ((item '((type . "album")
                 (id . "MPRE1")
                 (title . "Album")
                 (browse-id . "MPRE1")
                 (in-library . t)))
         (detail-source (ytm-radio--make-source
                         :id "ytm:browse:MPRE1:header"
                         :kind 'youtube-music-album
                         :title "Album"
                         :url "https://music.youtube.com/browse/MPRE1"
                         :in-library t))
         (home-source (ytm-radio--make-source
                       :id "ytm:home:albums"
                       :kind 'youtube-music-home-section
                       :title "Albums"
                       :items (list item)))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt detail-source :id)))
                (cons :browse-id "MPRE1")))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt detail-source :id) detail-source)
                          (cons (map-elt home-source :id) home-source))))
         (ytm-radio-helper-auth-file nil)
         called-arguments)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success
                          (ytm-radio-test--detail-helper-data
                           "MPRE1" "youtube-music-album" "Album"
                           '(in-library . nil)))))
              ((symbol-function 'ytm-radio--render-browser) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-toggle-detail-library)
      (should (equal called-arguments
                     '("item-library" "MPRE1" "remove")))
      (let ((refreshed (ytm-radio--source "ytm:browse:MPRE1:header")))
        (should refreshed)
        (should-not (map-elt refreshed :in-library))
        (should (map-elt refreshed :in-library-known)))
      (should-not (ytm-radio--truthy-field-p item :in-library))
      (should (map-elt item 'in-library)))))

(ert-deftest ytm-radio-toggle-detail-subscription-applies-refreshed-source ()
  "Toggle subscription status and replace the current detail from helper data."
  (let* ((item '((type . "artist")
                 (id . "UC1")
                 (title . "Artist")
                 (browse-id . "UC1")))
         (detail-source (ytm-radio--make-source
                         :id "ytm:browse:UC1:header"
                         :kind 'youtube-music-artist
                         :title "Artist Name"
                         :url "https://music.youtube.com/browse/UC1"))
         (home-source (ytm-radio--make-source
                       :id "ytm:home:artists"
                       :kind 'youtube-music-home-section
                       :title "Artists"
                       :items (list item)))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt detail-source :id)))
                (cons :browse-id "UC1")))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt detail-source :id) detail-source)
                          (cons (map-elt home-source :id) home-source))))
         (ytm-radio-helper-auth-file nil)
         called-arguments)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success
                          (ytm-radio-test--detail-helper-data
                           "UC1" "youtube-music-artist" "Artist Name"
                           '(subscribed . t)))))
              ((symbol-function 'ytm-radio--render-browser) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-toggle-detail-subscription)
      (should (equal called-arguments
                     '("subscription" "UC1" "subscribe")))
      (should (map-elt (ytm-radio--source "ytm:browse:UC1:header")
                       :subscribed))
      (should (ytm-radio--truthy-field-p item :subscribed))
      (should-not (assq 'subscribed item)))))

(ert-deftest ytm-radio-toggle-detail-subscription-unsubscribes-subscribed-source ()
  "Unsubscribe an already-subscribed artist/channel detail."
  (let* ((detail-source (ytm-radio--make-source
                         :id "ytm:browse:UC1:header"
                         :kind 'youtube-music-artist
                         :title "Artist Name"
                         :url "https://music.youtube.com/browse/UC1"
                         :subscribed t))
         (ytm-radio--browser-view
          (list (cons :kind 'detail)
                (cons :source-ids (list (map-elt detail-source :id)))
                (cons :browse-id "UC1")))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt detail-source :id) detail-source))))
         (ytm-radio-helper-auth-file nil)
         called-arguments)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success
                          (ytm-radio-test--detail-helper-data
                           "UC1" "youtube-music-artist" "Artist Name"
                           '(subscribed . nil)))))
              ((symbol-function 'ytm-radio--render-browser) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-toggle-detail-subscription)
      (should (equal called-arguments
                     '("subscription" "UC1" "unsubscribe")))
      (let ((refreshed (ytm-radio--source "ytm:browse:UC1:header")))
        (should refreshed)
        (should-not (map-elt refreshed :subscribed))
        (should (map-elt refreshed :subscribed-known))))))

(ert-deftest ytm-radio-start-current-track-mix-sets-runtime-queue ()
  "Start mix by loading helper tracks into the runtime queue."
  (let* ((track (ytm-radio--make-track
                 :id "local-id"
                 :title "Seed"
                 :url "https://music.youtube.com/watch?v=abc123_DEF4"))
         (ytm-radio--player (ytm-radio--make-player :current-track track))
         (ytm-radio-helper-auth-file nil)
         (ytm-radio-helper-library-limit 2)
         called-arguments
         played-track)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success
                          (list
                           (cons
                            'sources
                            (list
                             (list
                              (cons 'id "radio")
                              (cons 'kind "youtube-music-radio")
                              (cons 'title "Radio")
                              (cons
                               'url
                               "https://music.youtube.com/watch?v=abc123_DEF4&list=RDAMVMabc123_DEF4")
                              (cons
                               'items
                               (list
                                (list
                                 (cons 'type "track")
                                 (cons 'id "abc123_DEF4")
                                 (cons 'title "Seed duplicate")
                                 (cons 'duration 208)
                                 (cons 'url
                                       "https://music.youtube.com/watch?v=abc123_DEF4"))
                                (list
                                 (cons 'type "track")
                                 (cons 'id "def456_GHI7")
                                 (cons 'title "Next")
                                 (cons 'url
                                       "https://music.youtube.com/watch?v=def456_GHI7")))))))))))
              ((symbol-function 'ytm-radio--play-track)
               (lambda (track)
                 (setq played-track track)))
              ((symbol-function 'message) #'ignore))
      (ytm-radio-start-current-track-mix)
      (should (equal called-arguments
                     '("radio" "abc123_DEF4" "--limit" "2")))
      (should (eq played-track track))
      (should (= (length (map-elt ytm-radio--player :queue)) 2))
      (should (eq (car (map-elt ytm-radio--player :queue)) track))
      (should (= (map-elt track :duration) 208))
      (should (equal (map-elt (cadr (map-elt ytm-radio--player :queue)) :id)
                     "def456_GHI7")))))

(ert-deftest ytm-radio-add-current-track-to-playlist-uses-selected-option ()
  "Fetch playlist options and add the current track to the selected playlist."
  (let* ((track (ytm-radio--make-track
                 :id "local-id"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=abc123_DEF4"))
         (ytm-radio--player (ytm-radio--make-player :current-track track))
         (ytm-radio-helper-auth-file nil)
         calls)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (push arguments calls)
                 (pcase (car arguments)
                   ("playlist-options"
                    (funcall success
                             '((options
                                . [((playlist-id . "pl1")
                                    (title . "Playlist")
                                    (subtitle . "Private"))]))))
                   ("add-to-playlist"
                    (funcall success '((video-id . "abc123_DEF4")
                                       (playlist-id . "pl1")))))))
              ((symbol-function 'completing-read)
               (lambda (&rest _args) "Playlist - Private"))
              ((symbol-function 'message) #'ignore))
      (ytm-radio-add-current-track-to-playlist)
      (should (equal (nreverse calls)
                     '(("playlist-options" "abc123_DEF4")
                       ("add-to-playlist" "abc123_DEF4" "pl1")))))))

(ert-deftest ytm-radio-current-track-queue-actions-update-runtime-queue ()
  "Insert and append the current track in the runtime queue."
  (let* ((track-a (ytm-radio--make-track
                   :id "a"
                   :title "A"
                   :url "https://music.youtube.com/watch?v=a"))
         (track-b (ytm-radio--make-track
                   :id "b"
                   :title "B"
                   :url "https://music.youtube.com/watch?v=b"))
         (ytm-radio--player
          (ytm-radio--make-player :current-track track-a
                                  :queue (list track-a track-b)
                                  :queue-index 0)))
    (cl-letf (((symbol-function 'message) #'ignore))
      (ytm-radio-play-current-track-next)
      (should (= (length (map-elt ytm-radio--player :queue)) 3))
      (should (equal (map-elt (nth 1 (map-elt ytm-radio--player :queue)) :id)
                     "a"))
      (should-not (eq (nth 1 (map-elt ytm-radio--player :queue)) track-a))
      (should (eq (ytm-radio--next-track track-a)
                  (nth 1 (map-elt ytm-radio--player :queue))))
      (ytm-radio-add-current-track-to-queue)
      (should (= (length (map-elt ytm-radio--player :queue)) 4))
      (should (equal (map-elt (car (last (map-elt ytm-radio--player :queue))) :id)
                     "a")))))

(ert-deftest ytm-radio-queue-view-renders-runtime-queue ()
  "Render the runtime queue even when no durable sources are imported."
  (let* ((track-a (ytm-radio--make-track
                   :id "a"
                   :title "Seed"
                   :url "https://music.youtube.com/watch?v=a"))
         (track-b (ytm-radio--make-track
                   :id "b"
                   :title "Next"
                   :url "https://music.youtube.com/watch?v=b"
                   :duration 214))
         (extra-tracks
          (cl-loop for index from 3 to 10
                   collect (ytm-radio--make-track
                            :id (format "v%d" index)
                            :title (format "Song %d" index)
                            :url (format "https://music.youtube.com/watch?v=v%d"
                                         index))))
         (ytm-radio--loaded t)
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--browser-view 'home)
         (ytm-radio--browser-history nil)
         (ytm-radio--player
          (ytm-radio--make-player :current-track track-a
                                  :queue (append (list track-a track-b)
                                                 extra-tracks)
                                  :queue-index 0
                                  :duration 208)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--show-buffer) #'ignore))
      (ytm-radio-queue))
    (should (eq ytm-radio--browser-view 'queue))
    (with-current-buffer "*ytm-radio*"
      (let ((contents (buffer-string)))
        (should (string-match-p "Queue" contents))
        (should (string-match-p "01[[:space:]]+Seed" contents))
        (should (string-match-p "3:28" contents))
        (should (string-match-p "02[[:space:]]+Next" contents))
        (should (string-match-p "10[[:space:]]+Song 10" contents))
        (should-not (string-match-p "more" contents))
        (should-not
         (string-match-p "No YouTube Music pages imported yet" contents))))
    (ytm-radio--set-browser-view
     (list (cons :kind 'section)
           (cons :source-id "ytm:runtime:queue")
           (cons :title "Queue"))
     t)
    (with-current-buffer "*ytm-radio*"
      (let ((contents (buffer-string)))
        (should (string-match-p "10[[:space:]]+Song 10" contents))
        (should-not (string-match-p "No content in this view yet" contents))))))

(ert-deftest ytm-radio-next-track-honors-repeat-and-shuffle ()
  "Choose next tracks using repeat and shuffle state."
  (let* ((track-a (ytm-radio--make-track
                   :id "a"
                   :title "A"
                   :url "https://music.youtube.com/watch?v=a"))
         (track-b (ytm-radio--make-track
                   :id "b"
                   :title "B"
                   :url "https://music.youtube.com/watch?v=b"))
         (source (ytm-radio--make-source
                  :id "s"
                  :kind 'youtube-music-library
                  :title "S"
                  :tracks (list track-a track-b)))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons "s" source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (should (ytm-radio--same-track-p (ytm-radio--next-track track-a)
                                     track-b))
    (should-not (ytm-radio--next-track track-b))
    (setf (map-elt ytm-radio--player :repeat) 'all)
    (should (ytm-radio--same-track-p (ytm-radio--next-track track-b)
                                     track-a))
    (should (ytm-radio--same-track-p (ytm-radio--previous-track track-a)
                                     track-b))
    (setf (map-elt ytm-radio--player :repeat) 'one)
    (should (ytm-radio--same-track-p (ytm-radio--next-track track-b t)
                                     track-b))
    (setf (map-elt ytm-radio--player :shuffle) t)
    (cl-letf (((symbol-function 'random) (lambda (_limit) 0)))
      (should (ytm-radio--same-track-p (ytm-radio--next-track track-a)
                                       track-b)))))

(ert-deftest ytm-radio-render-now-playing-does-not-park-point-at-end ()
  "Keep now-playing point from drifting to the bottom after render."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"
                :artist "Artist"
                :duration 185))
        (ytm-radio--player
         (ytm-radio--make-player :status 'playing
                                 :position 42
                                 :duration 185)))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render-now-playing)
    (with-current-buffer "*ytm-radio-now-playing*"
      (goto-char (point-max))
      (ytm-radio--render-now-playing)
      (should-not (eobp))
      (should (= (point) (point-min))))))

(ert-deftest ytm-radio-render-now-playing-idle-shows-play-control ()
  "Render a play control when a track is selected but not playing."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"))
        (ytm-radio--player
         (ytm-radio--make-player :status 'idle)))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render-now-playing)
    (with-current-buffer "*ytm-radio-now-playing*"
      (should (string-match-p ">" (buffer-string)))
      (should-not (string-match-p "||" (buffer-string)))
      (should (string-match-p
               "0:00 ▱+ --:--"
               (buffer-string))))))

(ert-deftest ytm-radio-progress-position-refresh-is-throttled ()
  "Throttle frequent position changes instead of rendering each update."
  (let ((ytm-radio--progress-render-timer nil)
        (ytm-radio--last-rendered-progress-key nil)
        (ytm-radio--player
         (ytm-radio--make-player
          :current-track (ytm-radio--make-track
                          :id "v1"
                          :title "Song"
                          :url "https://music.youtube.com/watch?v=v1")
          :duration 185))
        (render-count 0))
    (cl-letf (((symbol-function 'ytm-radio--render-now-playing)
               (lambda ()
                 (cl-incf render-count)))
              ((symbol-function 'ytm-radio--now-playing-visible-p)
               (lambda () t)))
      (unwind-protect
          (progn
            (ytm-radio--set-playback-property :position 1)
            (ytm-radio--set-playback-property :position 2)
            (should (= render-count 0))
            (should (timerp ytm-radio--progress-render-timer)))
        (ytm-radio--cancel-progress-render)))))

(ert-deftest ytm-radio-progress-refresh-default-is-responsive ()
  "Keep the default progress refresh below one display second."
  (should (<= ytm-radio-progress-refresh-interval 0.5)))

(ert-deftest ytm-radio-progress-position-skips-same-display-second ()
  "Skip progress redraws when the visible playback second has not changed."
  (let* ((track (ytm-radio--make-track
                 :id "v1"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=v1"
                 :duration 185))
         (ytm-radio--player
          (ytm-radio--make-player
           :current-track track
           :position 1.2
           :duration 185))
         (ytm-radio--progress-render-timer nil)
         (ytm-radio--last-rendered-progress-key
          (list "v1" 1 185)))
    (cl-letf (((symbol-function 'ytm-radio--now-playing-visible-p)
               (lambda () t)))
      (ytm-radio--set-playback-property :position 1.8)
      (should-not ytm-radio--progress-render-timer))))

(ert-deftest ytm-radio-doctor-report-checks-local-setup ()
  "Report executable, data directory, and auth file status."
  (let* ((directory (make-temp-file "ytm-radio-doctor-" t))
         (program (expand-file-name "program" directory))
         (auth-file (expand-file-name "auth.json" directory))
         (ytm-radio-helper-command program)
         (ytm-radio-mpv-program program)
         (ytm-radio-yt-dlp-program program)
         (ytm-radio-data-directory directory)
         (ytm-radio-helper-auth-file auth-file))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\n")
            (insert "printf '%s\\n' '{\"ok\":true,\"schema\":1,\"protocol\":1,\"helper-version\":\"")
            (insert ytm-radio--helper-version)
            (insert "\",\"data\":{\"schema\":1,\"protocol\":1,\"helper-version\":\"")
            (insert ytm-radio--helper-version)
            (insert "\"},\"warnings\":[]}'\n"))
          (set-file-modes program #o700)
          (with-temp-file auth-file
            (insert "{}"))
          (let ((report (ytm-radio--doctor-report)))
            (should (string-match-p "^helper[[:space:]]+OK" report))
            (should (string-match-p "^protocol[[:space:]]+OK" report))
            (should (string-match-p "^mpv[[:space:]]+OK" report))
            (should (string-match-p "^yt-dlp[[:space:]]+OK" report))
            (should (string-match-p "^data-dir[[:space:]]+OK" report))
            (should (string-match-p "^auth[[:space:]]+OK" report))))
      (delete-directory directory t))))

(ert-deftest ytm-radio-ensure-program-reports-missing-absolute-path ()
  "Report missing absolute helper paths without blaming `exec-path'."
  (let* ((missing (expand-file-name "missing-helper" temporary-file-directory))
         (error (should-error
                 (ytm-radio--ensure-program missing "ytm-radio-helper")
                 :type 'user-error)))
    (should (string-match-p "Cannot execute ytm-radio-helper at"
                            (error-message-string error)))
    (should-not (string-match-p "exec-path" (error-message-string error)))))

(ert-deftest ytm-radio-ensure-program-reports-missing-command-name ()
  "Report missing command names through `exec-path'."
  (let* ((command "ytm-radio-test-missing-helper")
         (error (should-error
                 (ytm-radio--ensure-program command "ytm-radio-helper")
                 :type 'user-error)))
    (should (string-match-p "Cannot find ytm-radio-helper"
                            (error-message-string error)))
    (should (string-match-p "exec-path" (error-message-string error)))))

(ert-deftest ytm-radio-helper-release-asset-name-detects-platform ()
  "Build helper release asset names from the current platform."
  (let ((system-type 'darwin)
        (system-configuration "aarch64-apple-darwin"))
    (should (equal (ytm-radio--helper-release-asset-name)
                   "ytm-radio-helper-aarch64-apple-darwin")))
  (let ((system-type 'darwin)
        (system-configuration "x86_64-apple-darwin"))
    (should (equal (ytm-radio--helper-release-asset-name)
                   "ytm-radio-helper-x86_64-apple-darwin")))
  (let ((system-type 'gnu/linux)
        (system-configuration "x86_64-pc-linux-gnu"))
    (should (equal (ytm-radio--helper-release-asset-name)
                   "ytm-radio-helper-x86_64-unknown-linux-gnu")))
  (let ((system-type 'windows-nt)
        (system-configuration "x86_64-pc-windows-msvc"))
    (should (equal (ytm-radio--helper-release-asset-name)
                   "ytm-radio-helper-x86_64-pc-windows-msvc.exe"))))

(ert-deftest ytm-radio-installed-helper-command-uses-platform-name ()
  "Use the platform-specific installed helper file name."
  (let ((system-type 'windows-nt)
        (ytm-radio-helper-install-directory
         (expand-file-name "ytm-radio-helper-bin" temporary-file-directory)))
    (should (string-suffix-p
             "ytm-radio-helper.exe"
             (ytm-radio--installed-helper-command)))))

(ert-deftest ytm-radio-helper-command-falls-back-to-installed-helper ()
  "Use the installed helper when the default repo helper is missing."
  (let* ((directory (make-temp-file "ytm-radio-helper-command-" t))
         (ytm-radio-helper-install-directory (expand-file-name "bin" directory))
         (ytm-radio--default-helper-command
          (expand-file-name "missing-repo-helper" directory))
         (ytm-radio-helper-command ytm-radio--default-helper-command)
         (installed (ytm-radio--installed-helper-command)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory installed) t)
          (with-temp-file installed
            (insert "#!/bin/sh\n"))
          (set-file-modes installed #o700)
          (should (equal (ytm-radio--helper-command) installed)))
      (delete-directory directory t))))

(ert-deftest ytm-radio-call-helper-missing-suggests-installer ()
  "Suggest the helper installer when the helper is missing."
  (let* ((directory (make-temp-file "ytm-radio-helper-missing-" t))
         (ytm-radio-helper-install-directory (expand-file-name "bin" directory))
         (ytm-radio--default-helper-command
          (expand-file-name "missing-repo-helper" directory))
         (ytm-radio-helper-command ytm-radio--default-helper-command)
         (error (should-error
                 (ytm-radio--call-helper-async nil #'ignore #'ignore)
                 :type 'user-error)))
    (unwind-protect
        (should (string-match-p "M-x ytm-radio-install-helper"
                                (error-message-string error)))
      (delete-directory directory t))))

(ert-deftest ytm-radio-ensure-helper-command-installs-after-confirmation ()
  "Install a missing default helper after user confirmation."
  (let* ((directory (make-temp-file "ytm-radio-helper-offer-install-" t))
         (ytm-radio-helper-install-directory (expand-file-name "bin" directory))
         (ytm-radio-helper-release-base-url
          "https://example.invalid/ytm-radio/releases/latest/download")
         (ytm-radio--default-helper-command
          (expand-file-name "missing-repo-helper" directory))
         (ytm-radio-helper-command ytm-radio--default-helper-command)
         (ytm-radio-helper-offer-install t)
         (system-type 'gnu/linux)
         (system-configuration "x86_64-pc-linux-gnu")
         (noninteractive nil)
         copied-url
         prompt)
    (unwind-protect
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (question)
                     (setq prompt question)
                     t))
                  ((symbol-function 'ytm-radio--copy-url-to-file)
                   (lambda (url file)
                     (setq copied-url url)
                     (with-temp-file file
                       (insert "#!/bin/sh\n")))))
          (let ((installed (ytm-radio--ensure-helper-command)))
            (should (string-match-p "Download ytm-radio-helper-x86_64-unknown-linux-gnu"
                                    prompt))
            (should (equal copied-url
                           "https://example.invalid/ytm-radio/releases/latest/download/ytm-radio-helper-x86_64-unknown-linux-gnu"))
            (should (equal installed (ytm-radio--installed-helper-command)))
            (should (equal ytm-radio-helper-command installed))
            (should (file-executable-p installed))))
      (delete-directory directory t))))

(ert-deftest ytm-radio-install-helper-downloads-release-asset ()
  "Download the current platform helper release asset."
  (let* ((directory (make-temp-file "ytm-radio-helper-install-" t))
         (ytm-radio-helper-install-directory (expand-file-name "bin" directory))
         (ytm-radio-helper-release-base-url
          "https://example.invalid/ytm-radio/releases/latest/download")
         (system-type 'darwin)
         (system-configuration "aarch64-apple-darwin")
         copied-url)
    (unwind-protect
        (cl-letf (((symbol-function 'ytm-radio--copy-url-to-file)
                   (lambda (url file)
                     (setq copied-url url)
                     (with-temp-file file
                       (insert "#!/bin/sh\n")))))
          (let ((installed (ytm-radio-install-helper t)))
            (should (equal copied-url
                           "https://example.invalid/ytm-radio/releases/latest/download/ytm-radio-helper-aarch64-apple-darwin"))
            (should (equal installed (ytm-radio--installed-helper-command)))
            (should (equal ytm-radio-helper-command installed))
            (should (file-executable-p installed))))
      (delete-directory directory t))))

(ert-deftest ytm-radio-progress-bar-renders-unicode ()
  "Render compact Unicode progress bars."
  (should (equal (substring-no-properties
                  (ytm-radio--progress-bar nil 185 10))
                 "▱▱▱▱▱▱▱▱▱▱"))
  (should (equal (substring-no-properties
                  (ytm-radio--progress-bar 42 185 10))
                 "▰▰▱▱▱▱▱▱▱▱"))
  (should (equal (substring-no-properties
                  (ytm-radio--progress-bar 185 185 10))
                 "▰▰▰▰▰▰▰▰▰▰"))
  (should (equal (substring-no-properties
                  (ytm-radio--progress-bar nil nil 10))
                 "▱▱▱▱▱▱▱▱▱▱")))

(ert-deftest ytm-radio-progress-bar-uses-filled-face ()
  "Render filled progress bar cells with a distinct face."
  (let ((bar (ytm-radio--progress-bar 42 185 10)))
    (should (eq (get-text-property 0 'face bar)
                'ytm-radio-progress-filled))
    (should (eq (get-text-property 2 'face bar)
                'shadow))))

(ert-deftest ytm-radio-playback-time-label-fits-text-width ()
  "Keep the full playback time label within the now-playing text width."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"
                :duration 185))
        (ytm-radio--player
         (ytm-radio--make-player :position 42
                                 :duration 185)))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) nil))
              ((symbol-function 'ytm-radio--now-playing-text-width)
               (lambda () 20)))
      (let ((label (ytm-radio--playback-time-label track)))
        (should (<= (string-width label) 20))
        (should (string-match-p "▰+▱+" label))))))

(ert-deftest ytm-radio-progress-bar-width-measures-actual-glyphs ()
  "Shrink the progress bar using the actual filled and empty glyph widths."
  (let ((pixel-width
         (lambda (string &optional _buffer)
           (let ((filled (cl-count ?▰ string))
                 (empty (cl-count ?▱ string)))
             (+ (* 4 (- (length string) filled empty))
                (* 10 filled)
                (* 20 empty))))))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t))
              ((symbol-function 'frame-char-width)
               (lambda (&optional _frame) 10))
              ((symbol-function 'ytm-radio--now-playing-text-width)
               (lambda () 30))
              ((symbol-function 'ytm-radio--now-playing-text-pixel-width)
               (lambda () 170))
              ((symbol-function 'string-pixel-width)
               pixel-width))
      (should (= (ytm-radio--progress-bar-width "0:42" "3:05" nil nil)
                 5)))))

(ert-deftest ytm-radio-progress-bar-width-uses-live-window-body ()
  "Shrink progress bars against the live child-frame body width."
  (let ((ytm-radio--frame 'child)
        (pixel-width
         (lambda (string &optional _buffer)
           (let ((filled (cl-count ?▰ string))
                 (empty (cl-count ?▱ string)))
             (+ (* 4 (- (length string) filled empty))
                (* 10 filled)
                (* 10 empty))))))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t))
              ((symbol-function 'frame-live-p)
               (lambda (frame) (eq frame 'child)))
              ((symbol-function 'frame-root-window)
               (lambda (_frame) 'window))
              ((symbol-function 'window-live-p)
               (lambda (window) (eq window 'window)))
              ((symbol-function 'window-body-width)
               (lambda (_window pixelwise)
                 (if pixelwise 120 12)))
              ((symbol-function 'frame-char-width)
               (lambda (&optional _frame) 10))
              ((symbol-function 'ytm-radio--now-playing-text-width)
               (lambda () 30))
              ((symbol-function 'string-pixel-width)
               pixel-width))
      (should (= (ytm-radio--now-playing-text-pixel-width) 120))
      (should (= (ytm-radio--progress-bar-width "0:00" "--:--" nil nil)
                 5)))))

(ert-deftest ytm-radio-show-child-frame-preserves-focus-when-visible ()
  "Do not remap or focus an already visible child frame during refresh."
  (let ((visible-count 0)
        (focus-count 0)
        selected-frame
        selected-window)
    (with-temp-buffer
      (cl-letf (((symbol-function 'ytm-radio--ensure-frame)
                 (lambda (_buffer) 'frame))
                ((symbol-function 'frame-visible-p)
                 (lambda (_frame) t))
                ((symbol-function 'make-frame-visible)
                 (lambda (_frame)
                   (cl-incf visible-count)))
                ((symbol-function 'select-frame-set-input-focus)
                 (lambda (_frame)
                   (cl-incf focus-count)))
                ((symbol-function 'selected-frame)
                 (lambda () 'parent-frame))
                ((symbol-function 'selected-window)
                 (lambda () 'parent-window))
                ((symbol-function 'frame-live-p)
                 (lambda (frame) (memq frame '(frame parent-frame))))
                ((symbol-function 'window-live-p)
                 (lambda (window) (eq window 'parent-window)))
                ((symbol-function 'select-frame)
                 (lambda (frame) (setq selected-frame frame)))
                ((symbol-function 'select-window)
                 (lambda (window) (setq selected-window window))))
        (should (eq (ytm-radio--show-child-frame (current-buffer) t) 'frame))
        (should (= visible-count 0))
        (should (= focus-count 0))
        (should (eq selected-frame 'parent-frame))
        (should (eq selected-window 'parent-window))))))

(ert-deftest ytm-radio-now-playing-text-areas-bind-mouse-drag ()
  "Bind rendered now-playing non-button text to frame movement."
  (let ((ytm-radio-display-style 'child-frame)
        (ytm-radio--frame 'child))
    (with-temp-buffer
      (insert "Title ")
      (ytm-radio--insert-now-playing-control ">" #'ignore "Play")
      (cl-letf (((symbol-function 'display-graphic-p)
                 (lambda (&optional _frame) t))
                ((symbol-function 'frame-live-p)
                 (lambda (frame) (eq frame 'child))))
        (ytm-radio--add-now-playing-drag-bindings))
      (should (eq (lookup-key (get-text-property (point-min) 'keymap)
                              [down-mouse-1])
                  #'ytm-radio--drag-now-playing))
      (search-backward ">")
      (should-not (eq (get-text-property (point) 'keymap)
                      ytm-radio--now-playing-drag-map)))))

(ert-deftest ytm-radio-now-playing-button-events-do-not-drag ()
  "Keep now-playing control button clicks from moving the frame."
  (with-temp-buffer
    (ytm-radio--insert-now-playing-control ">" #'ignore "Play")
    (let ((buffer (current-buffer))
          (point (point-min)))
      (cl-letf (((symbol-function 'event-start)
                 (lambda (_event) 'position))
                ((symbol-function 'posn-window)
                 (lambda (_position) 'window))
                ((symbol-function 'posn-point)
                 (lambda (_position) point))
                ((symbol-function 'window-live-p)
                 (lambda (window) (eq window 'window)))
                ((symbol-function 'window-buffer)
                 (lambda (_window) buffer)))
        (should (ytm-radio--now-playing-button-event-p 'event))))))

(ert-deftest ytm-radio-now-playing-mouse-1-button-does-not-select-window ()
  "Activate now-playing buttons with mouse-1 without selecting their window."
  (let ((called nil)
        (selected nil))
    (with-temp-buffer
      (ytm-radio--insert-now-playing-control ">"
                                             (lambda ()
                                               (interactive)
                                               (setq called t))
                                             "Play")
      (let ((buffer (current-buffer))
            (point (point-min)))
        (cl-letf (((symbol-function 'event-start)
                   (lambda (_event) 'position))
                  ((symbol-function 'posn-window)
                   (lambda (_position) 'window))
                  ((symbol-function 'posn-point)
                   (lambda (_position) point))
                  ((symbol-function 'window-live-p)
                   (lambda (window) (eq window 'window)))
                  ((symbol-function 'window-buffer)
                   (lambda (_window) buffer))
                  ((symbol-function 'select-window)
                   (lambda (&rest _args)
                     (setq selected t))))
          (ytm-radio--push-now-playing-button 'event)
          (should called)
          (should-not selected))))))

(ert-deftest ytm-radio-now-playing-buttons-override-inert-mouse-events ()
  "Keep now-playing control buttons clickable despite inert buffer clicks."
  (should (eq (lookup-key ytm-radio--now-playing-button-map [mouse-1])
              #'ytm-radio--push-now-playing-button))
  (should (eq (lookup-key ytm-radio--now-playing-button-map [mouse-2])
              #'ytm-radio--push-now-playing-button))
  (dolist (event '([down-mouse-1] [drag-mouse-1]
                   [double-mouse-1] [triple-mouse-1]
                   [down-mouse-2] [drag-mouse-2]
                   [double-mouse-2] [triple-mouse-2]
                   [mouse-3] [down-mouse-3] [drag-mouse-3]
                   [double-mouse-3] [triple-mouse-3]))
    (should (eq (lookup-key ytm-radio--now-playing-button-map event)
                #'ignore))))

(ert-deftest ytm-radio-drag-now-playing-remembers-manual-position ()
  "Move the child frame and remember the dragged position."
  (let ((ytm-radio--frame 'child)
        (ytm-radio--frame-manual-position nil)
        (events '((mouse-movement) mouse-1))
        (mouse-positions '((10 . 10) (35 . 45)))
        (frame-position '(20 . 30))
        set-position)
    (with-temp-buffer
      (let ((buffer (current-buffer)))
        (cl-letf (((symbol-function 'frame-live-p)
                   (lambda (frame) (eq frame 'child)))
                  ((symbol-function 'event-start)
                   (lambda (_event) 'position))
                  ((symbol-function 'posn-window)
                   (lambda (_position) 'window))
                  ((symbol-function 'posn-point)
                   (lambda (_position) 1))
                  ((symbol-function 'window-live-p)
                   (lambda (window) (eq window 'window)))
                  ((symbol-function 'window-frame)
                   (lambda (_window) 'child))
                  ((symbol-function 'window-buffer)
                   (lambda (_window) buffer))
                  ((symbol-function 'button-at)
                   (lambda (_position) nil))
                  ((symbol-function 'mouse-absolute-pixel-position)
                   (lambda () (pop mouse-positions)))
                  ((symbol-function 'frame-position)
                   (lambda (_frame) frame-position))
                  ((symbol-function 'frame-parent)
                   (lambda (frame) (and (eq frame 'child) 'parent)))
                  ((symbol-function 'frame-pixel-width)
                   (lambda (frame) (if (eq frame 'parent) 200 50)))
                  ((symbol-function 'frame-pixel-height)
                   (lambda (frame) (if (eq frame 'parent) 180 40)))
                  ((symbol-function 'set-frame-position)
                   (lambda (frame left top)
                     (setq frame-position (cons left top)
                           set-position (list frame left top))))
                  ((symbol-function 'read-event)
                   (lambda (&rest _args) (pop events))))
          (ytm-radio--drag-now-playing 'event))))
    (should (equal set-position '(child 45 65)))
    (should (equal ytm-radio--frame-manual-position '(45 . 65)))))

(ert-deftest ytm-radio-position-frame-preserves-manual-position ()
  "Keep dragged child-frame coordinates across refresh repositioning."
  (let ((ytm-radio--frame-manual-position '(260 . 180))
        position)
    (cl-letf (((symbol-function 'frame-parent)
               (lambda (frame) (and (eq frame 'child) 'parent)))
              ((symbol-function 'frame-pixel-width)
               (lambda (frame) (if (eq frame 'parent) 300 100)))
              ((symbol-function 'frame-pixel-height)
               (lambda (frame) (if (eq frame 'parent) 200 80)))
              ((symbol-function 'set-frame-position)
               (lambda (frame left top)
                 (setq position (list frame left top)))))
      (ytm-radio--position-frame 'child)
      (should (equal position '(child 200 120)))
      (should (equal ytm-radio--frame-manual-position '(200 . 120))))))

(ert-deftest ytm-radio-ensure-frame-clears-stale-manual-position ()
  "Do not reuse dragged coordinates for a newly-created child frame."
  (let ((ytm-radio--frame 'dead)
        (ytm-radio--frame-manual-position '(20 . 30))
        frame-parameters
        focus-redirection
        window-parameters)
    (with-temp-buffer
      (cl-letf (((symbol-function 'frame-live-p)
                 (lambda (frame) (eq frame 'new)))
                ((symbol-function 'selected-frame)
                 (lambda () 'parent))
                ((symbol-function 'frame-parent)
                 (lambda (frame) (and (eq frame 'new) 'parent)))
                ((symbol-function 'make-frame)
                 (lambda (parameters)
                   (setq frame-parameters parameters)
                   'new))
                ((symbol-function 'redirect-frame-focus)
                 (lambda (frame parent)
                   (setq focus-redirection (list frame parent))))
                ((symbol-function 'ytm-radio--apply-child-frame-border-face)
                 #'ignore)
                ((symbol-function 'frame-root-window)
                 (lambda (_frame) 'window))
                ((symbol-function 'set-window-buffer)
                 #'ignore)
                ((symbol-function 'set-window-dedicated-p)
                 #'ignore)
                ((symbol-function 'set-window-parameter)
                 (lambda (window parameter value)
                   (push (list window parameter value) window-parameters)))
                ((symbol-function 'set-window-fringes)
                 #'ignore)
                ((symbol-function 'set-window-margins)
                 #'ignore)
                ((symbol-function 'set-window-scroll-bars)
                 #'ignore)
                ((symbol-function 'ytm-radio--fit-frame)
                 #'ignore)
                ((symbol-function 'ytm-radio--position-frame)
                 #'ignore))
        (should (eq (ytm-radio--ensure-frame (current-buffer)) 'new))
        (should (eq (alist-get 'no-focus-on-map frame-parameters) t))
        (should (eq (alist-get 'no-accept-focus frame-parameters) t))
        (should (equal focus-redirection '(new parent)))
        (should (member '(window no-other-window t) window-parameters))
        (should (member '(window no-delete-other-windows t)
                        window-parameters))
        (should-not ytm-radio--frame-manual-position)))))

(ert-deftest ytm-radio-now-playing-buffer-hides-tab-line ()
  "Keep external tab-line settings out of the now-playing buffer."
  (let ((ytm-radio--now-playing-buffer-name
         " *ytm-radio-test-now-playing*")
        (tab-line-format '("external tab line")))
    (unwind-protect
        (with-current-buffer (ytm-radio--now-playing-buffer)
          (should (local-variable-p 'tab-line-format))
          (should-not tab-line-format))
      (kill-buffer ytm-radio--now-playing-buffer-name))))

(ert-deftest ytm-radio-child-frame-border-uses-dedicated-face ()
  "Apply the ytm-radio child-frame border face instead of shadow."
  (let* ((frame (selected-frame))
         (expected (face-background 'ytm-radio-child-frame-border frame t)))
    (ytm-radio--apply-child-frame-border-face frame)
    (should (equal (face-background 'child-frame-border frame t)
                   expected))))

(ert-deftest ytm-radio-thumbnail-url-falls-back-to-youtube-id ()
  "Build a thumbnail URL from the video id when no thumbnail is stored."
  (let ((track (ytm-radio--make-track
                :id "abc_123"
                :title "Song"
                :url "https://music.youtube.com/watch?v=abc_123")))
    (should (equal (ytm-radio--track-thumbnail-url track)
                   "https://i.ytimg.com/vi/abc_123/hqdefault.jpg"))))

(ert-deftest ytm-radio-thumbnail-url-requests-larger-cdn-images ()
  "Request larger variants of YouTube/Google CDN thumbnail URLs."
  (let ((source (ytm-radio--make-source
                 :id "ytm:browse:UC1:header"
                 :kind 'youtube-music-artist
                 :title "Artist"
                 :thumbnail-url
                 "https://yt3.googleusercontent.com/avatar=w120-h120-p-l90-rj"))
        (track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :thumbnail-url
                "https://yt3.ggpht.com/avatar=s120-c-k-c0x00ffffff-no-rj")))
    (should (equal (ytm-radio--source-thumbnail-url source)
                   "https://yt3.googleusercontent.com/avatar=w544-h544-p-l90-rj"))
    (should (equal (ytm-radio--track-thumbnail-url track)
                   "https://yt3.ggpht.com/avatar=s544-c-k-c0x00ffffff-no-rj"))))

(ert-deftest ytm-radio-scaled-cover-size-preserves-aspect-ratio ()
  "Scale each cover independently within the configured bounds."
  (let ((ytm-radio-cover-max-width 200)
        (ytm-radio-cover-max-height 180))
    (should (equal (ytm-radio--scaled-cover-size 1600 900)
                   '(200 . 112)))
    (should (equal (ytm-radio--scaled-cover-size 800 800)
                   '(180 . 180)))
    (should (< (car (ytm-radio--scaled-cover-size 800 800))
               (car (ytm-radio--scaled-cover-size 1600 900))))))

(ert-deftest ytm-radio-item-type-detects-internal-tracks ()
  "Classify internal keyword-alist tracks as tracks in the browser buffer."
  (let ((track (ytm-radio--make-track
                :id "abc_123"
                :title "Song"
                :url "https://music.youtube.com/watch?v=abc_123"
                :source-id "source")))
    (should (equal (ytm-radio--item-type track) "track"))
    (should (equal (ytm-radio--item-thumbnail-url track)
                   "https://i.ytimg.com/vi/abc_123/hqdefault.jpg"))))

(ert-deftest ytm-radio-item-detail-filters-menu-actions ()
  "Do not render YouTube Music menu actions as item metadata."
  (should (equal (ytm-radio--item-detail
                  '((type . "album")
                    (title . "30")
                    (subtitle . "Album - Adele - Shuffle play - Start mix - Album added to queue - Save album to library - Remove album from library - Album will play next - Play next")))
                 "Album - Adele"))
  (should (equal (ytm-radio--item-detail
                  '((type . "playlist")
                    (title . "Lofi Loft")
                    (subtitle . "Playlist - Evil Needle - Playlist added to queue - Save playlist to library - Remove playlist from library - Save to playlist - Playlist will play next - Play next")))
                 "Playlist - Evil Needle"))
  (should (string-empty-p
           (ytm-radio--item-detail
            '((type . "playlist")
              (title . "Lofi Loft")
              (subtitle . "Shuffle play - Start mix - Playlist will play next - Play next"))))))

(ert-deftest ytm-radio-source-subtitle-filters-menu-actions ()
  "Do not render YouTube Music menu actions as source metadata."
  (let ((source (ytm-radio--make-source
                 :id "ytm:browse:MPRE1:header"
                 :kind 'youtube-music-album
                 :title "Album"
                 :subtitle "Album - Artist - Album added to queue - Save album to library - Remove album from library")))
    (should (equal (ytm-radio--source-subtitle source)
                   "Album • Artist"))))

(ert-deftest ytm-radio-source-subtitle-filters-header-actions ()
  "Do not render YouTube Music header controls as source metadata."
  (let ((source (ytm-radio--make-source
                 :id "ytm:browse:UC1:header"
                 :kind 'youtube-music-artist
                 :title "Chill girl Vibes"
                 :subtitle "448K monthly audience - More - Less - Mix - Subscribe - Unsubscribe - Unsubscribe from - ? - 85")))
    (should (equal (ytm-radio--source-subtitle source)
                   "448K monthly audience"))))

(ert-deftest ytm-radio-item-metadata-renders-clickable-browse-tokens ()
  "Render structured item metadata as browse buttons."
  (let* ((source (ytm-radio--make-source
                  :id "source"
                  :kind 'youtube-music-home-section
                  :title "Home"))
         (metadata (list '((text . "Album"))
                         '((text . " - Kolisnik")
                           (browse-id . "UCKOL")
                           (browse-params . "artist-params"))
                         '((text . " & "))
                         '((text . "LoFi Beats")
                           (browse-id . "UCLOFI"))))
         (item `((type . "album")
                 (title . "Smoke Rings")
                 (metadata . ,metadata)))
         opened)
    (with-temp-buffer
      (cl-letf (((symbol-function 'ytm-radio--item-thumbnail-image)
                 (lambda (_item) nil))
                ((symbol-function 'ytm-radio--open-browse-id-as-source)
                 (lambda (browse-id &optional params)
                   (setq opened (cons browse-id params)))))
        (ytm-radio--insert-source-item source item 1)
        (goto-char (point-min))
        (search-forward "Kolisnik")
        (should (button-at (1- (point))))
        (push-button (1- (point)))
        (should (equal opened '("UCKOL" . "artist-params")))))))

(ert-deftest ytm-radio-helper-episode-items-are-playable ()
  "Treat helper podcast episodes as playable items."
  (let* ((source (ytm-radio--source-from-helper
                  '((id . "search")
                    (kind . "youtube-music-search")
                    (title . "Search")
                    (items . (((type . "episode")
                               (id . "episode1")
                               (title . "Episode")
                               (url . "https://music.youtube.com/watch?v=episode1")))))))
         (track (car (map-elt source :tracks))))
    (should track)
    (should (equal (map-elt track :id) "episode1"))
    (cl-letf (((symbol-function 'ytm-radio--mdicon)
               (lambda (_name fallback) fallback)))
      (should (equal (ytm-radio--item-type-label '((type . "podcast"))) "POD"))
      (should (equal (ytm-radio--item-type-label '((type . "episode"))) "EP")))))

(ert-deftest ytm-radio-source-display-title-hides-internal-browse-ids ()
  "Do not show YouTube Music internal browse ids as source titles."
  (let ((source (ytm-radio--make-source
                 :id "ytm:browse:VLPL0xLD9YNV927g2-XOMbe9AXto5UDYR-Ff:header"
                 :kind 'youtube-music-playlist
                 :title "VLPL0xLD9YNV927g2-XOMbe9AXto5UDYR-Ff")))
    (should (equal (ytm-radio--source-display-title source) "Playlist"))))

(ert-deftest ytm-radio-helper-browse-arguments-include-limit ()
  "Build Rust helper arguments for library imports."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-library-limit 25)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-browse-arguments "library")
                   '("browse"
                     "library"
                     "--auth"
                     "/tmp/auth.json"
                     "--limit"
                     "25")))))

(ert-deftest ytm-radio-helper-home-initial-arguments-include-initial-only ()
  "Build Rust helper arguments for non-blocking Home imports."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-home-limit 12)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-browse-arguments "home" t)
                   '("browse"
                     "home"
                     "--auth"
                     "/tmp/auth.json"
                     "--initial-only"
                     "--limit"
                     "12")))))

(ert-deftest ytm-radio-helper-continuation-arguments-include-limit ()
  "Build Rust helper arguments for Home continuation imports."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-home-limit 12)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-continuation-arguments "next-page")
                   '("continuation"
                     "next-page"
                     "--auth"
                     "/tmp/auth.json"
                     "--limit"
                     "12")))))

(ert-deftest ytm-radio-helper-search-arguments-include-limit ()
  "Build Rust helper arguments for search imports."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-library-limit 25)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-search-arguments "tokyo")
                   '("search"
                     "tokyo"
                     "--auth"
                     "/tmp/auth.json"
                     "--limit"
                     "25")))))

(ert-deftest ytm-radio-helper-rate-arguments-include-auth ()
  "Build Rust helper arguments for rating tracks."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-rate-arguments "v1" "like")
                   '("rate"
                     "v1"
                     "like"
                     "--auth"
                     "/tmp/auth.json")))))

(ert-deftest ytm-radio-helper-track-status-arguments-include-auth ()
  "Build Rust helper arguments for track account status."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-track-status-arguments "v1")
                   '("track-status"
                     "v1"
                     "--auth"
                     "/tmp/auth.json")))))

(ert-deftest ytm-radio-helper-current-action-arguments-include-auth ()
  "Build Rust helper arguments for current-track actions."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-library-limit 25)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-radio-arguments "v1")
                   '("radio"
                     "v1"
                     "--auth"
                     "/tmp/auth.json"
                     "--limit"
                     "25")))
    (should (equal (ytm-radio--helper-playlist-options-arguments "v1")
                   '("playlist-options"
                     "v1"
                     "--auth"
                     "/tmp/auth.json")))
    (should (equal (ytm-radio--helper-add-to-playlist-arguments "v1" "pl1")
                   '("add-to-playlist"
                     "v1"
                     "pl1"
                     "--auth"
                     "/tmp/auth.json")))
    (should (equal (ytm-radio--helper-library-arguments "v1" "toggle")
                   '("library"
                     "v1"
                     "toggle"
                     "--auth"
                     "/tmp/auth.json")))
    (should (equal (ytm-radio--helper-item-library-arguments
                    "VLPL1" "toggle" "ggMCCAI%3D")
                   '("item-library"
                     "VLPL1"
                     "toggle"
                     "--params"
                     "ggMCCAI%3D"
                     "--auth"
                     "/tmp/auth.json")))
    (should (equal (ytm-radio--helper-subscription-arguments
                    "UC1" "toggle" nil)
                   '("subscription"
                     "UC1"
                     "toggle"
                     "--auth"
                     "/tmp/auth.json")))))

(ert-deftest ytm-radio-helper-browse-id-arguments-include-limit ()
  "Build Rust helper arguments for detail browse imports."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-library-limit 25)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-browse-id-arguments "VLPL1")
                   '("browse-id"
                     "VLPL1"
                     "--auth"
                     "/tmp/auth.json"
                     "--limit"
                     "25")))))

(ert-deftest ytm-radio-helper-browse-id-arguments-include-params ()
  "Pass YouTube Music browse endpoint params to the helper."
  (let ((ytm-radio-helper-auth-file nil)
        (ytm-radio-helper-library-limit 25)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-browse-id-arguments "VLPL1" "ggMCCAI%3D")
                   '("browse-id"
                     "VLPL1"
                     "--params"
                     "ggMCCAI%3D"
                     "--limit"
                     "25")))))

(ert-deftest ytm-radio-helper-arguments-include-proxy ()
  "Build Rust helper arguments with the first-class proxy setting."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-library-limit 25)
        (ytm-radio-proxy-url "socks5h://127.0.0.1:7890"))
    (should (equal (ytm-radio--helper-search-arguments "tokyo")
                   '("search"
                     "tokyo"
                     "--auth"
                     "/tmp/auth.json"
                     "--proxy"
                     "socks5h://127.0.0.1:7890"
                     "--limit"
                     "25")))
    (should (equal (ytm-radio--helper-radio-arguments "v1")
                   '("radio"
                     "v1"
                     "--auth"
                     "/tmp/auth.json"
                     "--proxy"
                     "socks5h://127.0.0.1:7890"
                     "--limit"
                     "25")))))

(ert-deftest ytm-radio-music-url-detail-browse-id-parses-playlists ()
  "Parse YouTube Music detail browse ids from non-track URLs."
  (should (equal (ytm-radio--music-url-detail-browse-id
                  "https://music.youtube.com/browse/MPRE1")
                 "MPRE1"))
  (should (equal (ytm-radio--music-url-detail-browse-id
                  "https://music.youtube.com/playlist?list=PL1")
                 "VLPL1"))
  (should-not (ytm-radio--music-url-detail-browse-id
               "https://music.youtube.com/watch?v=v1")))

(ert-deftest ytm-radio-item-detail-browse-prefers-item-endpoint ()
  "Use helper-provided endpoint params before synthesized playlist ids."
  (let ((item '((type . "playlist")
                (id . "PLFALLBACK")
                (title . "Playlist")
                (browse-id . "VLREAL")
                (browse-params . "ggMCCAI%3D")
                (playlist-id . "PLFALLBACK"))))
    (should (equal (ytm-radio--item-detail-browse item)
                   '("VLREAL" . "ggMCCAI%3D")))))

(ert-deftest ytm-radio-item-detail-browse-supports-channel-items ()
  "Open channel items through the account helper."
  (let ((item '((type . "channel")
                (id . "UCchannel")
                (title . "Channel"))))
    (should (equal (ytm-radio--item-detail-browse item)
                   '("UCchannel")))))

(ert-deftest ytm-radio-open-item-expands-non-track-through-helper ()
  "Open playlist-like items with the helper instead of yt-dlp."
  (let ((source (ytm-radio--make-source
                 :id "source"
                 :kind 'youtube-music-home
                 :title "Home"
                 :items nil))
        (item '((type . "playlist")
                (id . "PL1")
                (title . "Playlist")
                (playlist-id . "PL1")
                (url . "https://music.youtube.com/playlist?list=PL1")))
        called-browse-id
        called-params
        called-context
        called-history-entry
        fetched-url)
    (cl-letf (((symbol-function 'ytm-radio--open-browse-id-as-source)
               (lambda (browse-id &optional params context history-entry)
                 (setq called-browse-id browse-id)
                 (setq called-params params)
                 (setq called-context context)
                 (setq called-history-entry history-entry)))
              ((symbol-function 'ytm-radio--open-url-as-source)
               (lambda (url)
                 (setq fetched-url url))))
      (ytm-radio--open-item source item)
      (should (equal called-browse-id "VLPL1"))
      (should-not called-params)
      (should (eq called-context item))
      (should called-history-entry)
      (should-not fetched-url))))

(ert-deftest ytm-radio-open-browse-id-enters-detail-view-for-sections ()
  "Show all returned detail sections instead of only the first source."
  (let* ((header (ytm-radio--make-source
                  :id "ytm:browse:UC1:header"
                  :kind 'youtube-music-artist
                  :title "Artist"
                  :url "https://music.youtube.com/browse/UC1"
                  :items nil
                  :tracks nil))
         (songs (ytm-radio--make-source
                 :id "ytm:browse:UC1:1:songs"
                 :kind 'youtube-music-detail-section
                 :title "Songs"
                 :url "https://music.youtube.com/browse/UC1"
                 :items nil
                 :tracks nil))
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--loaded t)
         (ytm-radio--browser-view 'home)
         (ytm-radio--browser-history nil)
         (ytm-radio--browser-load-process nil))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (_arguments success _error-callback)
                 (funcall success 'data)
                 nil))
              ((symbol-function 'ytm-radio--helper-sources)
               (lambda (_data) (list header songs)))
              ((symbol-function 'ytm-radio--save) #'ignore))
      (ytm-radio--open-browse-id-as-source "UC1")
      (should (eq (ytm-radio--view-kind) 'detail))
      (should (equal (ytm-radio--view-value :source-ids)
                     '("ytm:browse:UC1:header"
                       "ytm:browse:UC1:1:songs")))
      (should (eq (ytm-radio--view-value :origin-view) 'home))
      (should (equal (mapcar #'ytm-radio--browser-history-entry-view
                             ytm-radio--browser-history)
                     '(home))))))

(ert-deftest ytm-radio-open-browse-id-single-source-uses-context-header ()
  "Show album/playlist detail headers even when the helper returns one source."
  (let* ((track (ytm-radio--make-track
                 :id "v1"
                 :title "Someone Like You"
                 :url "https://music.youtube.com/watch?v=v1"
                 :duration 286))
         (source (ytm-radio--make-source
                  :id "ytm:browse:VLPL1"
                  :kind 'youtube-music-playlist
                  :title "Playlist"
                  :url "https://music.youtube.com/browse/VLPL1"
                  :items (list track)
                  :tracks (list track)))
         (item '((type . "playlist")
                 (title . "Adele Mix")
                 (subtitle . "Playlist - YouTube Music")
                 (thumbnail-url . "https://example.com/adele-mix.jpg")))
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--loaded t)
         (ytm-radio--browser-view 'home)
         (ytm-radio--browser-history nil)
         (ytm-radio--browser-load-process nil))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (_arguments success _error-callback)
                 (funcall success 'data)
                 nil))
              ((symbol-function 'ytm-radio--helper-sources)
               (lambda (_data) (list source)))
              ((symbol-function 'ytm-radio--save) #'ignore))
      (ytm-radio--open-browse-id-as-source "VLPL1" nil item)
      (should (eq (ytm-radio--view-kind) 'detail))
      (should (equal (ytm-radio--view-value :source-ids)
                     '("ytm:browse:VLPL1:header"
                       "ytm:browse:VLPL1")))
      (let ((header (ytm-radio--source "ytm:browse:VLPL1:header")))
        (should (eq (map-elt header :kind) 'youtube-music-playlist))
        (should (equal (map-elt header :title) "Adele Mix"))
        (should (equal (map-elt header :thumbnail-url)
                       "https://example.com/adele-mix.jpg")))
      (should (eq (ytm-radio--view-value :origin-view) 'home))
      (should (equal (mapcar #'ytm-radio--browser-history-entry-view
                             ytm-radio--browser-history)
                     '(home))))))

(ert-deftest ytm-radio-back-restores-position-after-detail-load ()
  "Return from async detail navigation to the item that opened it."
  (let* ((source-a (ytm-radio--make-source
                    :id "ytm:home:first"
                    :kind 'youtube-music-home-section
                    :title "First"
                    :items '(((type . "track")
                              (id . "a")
                              (title . "Song A")
                              (url . "https://music.youtube.com/watch?v=a")))))
         (item-b '((type . "playlist")
                   (id . "VLPL1")
                   (title . "Adele Mix")
                   (browse-id . "VLPL1")
                   (subtitle . "Playlist - YouTube Music")))
         (source-b (ytm-radio--make-source
                    :id "ytm:home:second"
                    :kind 'youtube-music-home-section
                    :title "Second"
                    :items (list item-b)))
         (detail (ytm-radio--make-source
                  :id "ytm:browse:VLPL1"
                  :kind 'youtube-music-playlist
                  :title "Adele Mix"
                  :items nil
                  :tracks nil))
         (ytm-radio--loaded t)
         (ytm-radio--browser-view 'home)
         (ytm-radio--browser-history nil)
         (ytm-radio--browser-load-process nil)
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt source-a :id) source-a)
                          (cons (map-elt source-b :id) source-b))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render-browser)
    (with-current-buffer "*ytm-radio*"
      (goto-char (point-min))
      (search-forward "Adele Mix")
      (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
                 (lambda (action &optional _message)
                   (funcall action)))
                ((symbol-function 'ytm-radio--call-helper-async)
                 (lambda (_arguments success _error-callback)
                   (funcall success 'data)
                   nil))
                ((symbol-function 'ytm-radio--helper-sources)
                 (lambda (_data) (list detail)))
                ((symbol-function 'ytm-radio--save) #'ignore))
        (ytm-radio-open-at-point))
      (should (eq (ytm-radio--view-kind) 'detail))
      (ytm-radio-back)
      (should (eq ytm-radio--browser-view 'home))
      (should (equal (ytm-radio--source-display-title
                      (ytm-radio--line-source-at-point))
                     "Second"))
      (should (equal (ytm-radio--item-title (ytm-radio--line-item-at-point))
                     "Adele Mix")))))

(ert-deftest ytm-radio-open-browse-id-preserves-root-origin ()
  "Keep the originating root tab active when opening detail views."
  (let* ((header (ytm-radio--make-source
                  :id "ytm:browse:UC1:header"
                  :kind 'youtube-music-artist
                  :title "Artist"
                  :url "https://music.youtube.com/browse/UC1"
                  :items nil
                  :tracks nil))
         (songs (ytm-radio--make-source
                 :id "ytm:browse:UC1:1:songs"
                 :kind 'youtube-music-detail-section
                 :title "Songs"
                 :url "https://music.youtube.com/browse/UC1"
                 :items nil
                 :tracks nil))
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--loaded t)
         (ytm-radio--browser-view 'library)
         (ytm-radio--browser-history nil)
         (ytm-radio--browser-load-process nil))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (_arguments success _error-callback)
                 (funcall success 'data)
                 nil))
              ((symbol-function 'ytm-radio--helper-sources)
               (lambda (_data) (list header songs)))
              ((symbol-function 'ytm-radio--save) #'ignore))
      (ytm-radio--open-browse-id-as-source "UC1")
      (should (eq (ytm-radio--view-kind) 'detail))
      (should (eq (ytm-radio--view-value :origin-view) 'library))
      (should (ytm-radio--browser-root-active-p 'library))
      (should-not (ytm-radio--browser-root-active-p 'home))
      (should (equal (mapcar #'ytm-radio--browser-history-entry-view
                             ytm-radio--browser-history)
                     '(library))))))

(ert-deftest ytm-radio-enter-source-preserves-root-origin ()
  "Keep the originating root tab active when focusing one section."
  (let ((source (ytm-radio--make-source
                 :id "ytm:home:listen"
                 :kind 'youtube-music-home-section
                 :title "Listen again"
                 :items nil
                 :tracks nil))
        (ytm-radio--state (ytm-radio--make-state))
        (ytm-radio--player (ytm-radio--make-player))
        (ytm-radio--loaded t)
        (ytm-radio--browser-view 'explore)
        (ytm-radio--browser-history nil))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--enter-source source)
    (should (eq (ytm-radio--view-kind) 'section))
    (should (eq (ytm-radio--view-value :origin-view) 'explore))
    (should (ytm-radio--browser-root-active-p 'explore))
    (should-not (ytm-radio--browser-root-active-p 'home))))

(ert-deftest ytm-radio-helper-login-arguments ()
  "Build Rust helper arguments for the browser login window."
  (let ((ytm-radio-helper-login-browser "dia")
        (ytm-radio-helper-login-profile-directory "/tmp/ytm-login-profile")
        (ytm-radio-helper-login-cdp-port 29999)
        (ytm-radio-helper-login-timeout 60)
        (ytm-radio-proxy-url "socks5h://127.0.0.1:7890"))
    (should
     (equal
      (ytm-radio--helper-login-arguments "/tmp/ytm-auth.json")
      '("auth"
        "login-window"
        "--output"
        "/tmp/ytm-auth.json"
        "--port"
        "29999"
        "--timeout-secs"
        "60"
        "--proxy"
        "socks5h://127.0.0.1:7890"
        "--profile-dir"
        "/tmp/ytm-login-profile"
        "--browser"
        "dia")))))

(ert-deftest ytm-radio-helper-login-arguments-auto-browser ()
  "Use helper browser defaults without explicit browser or profile overrides."
  (let ((ytm-radio-helper-login-browser nil)
        (ytm-radio-helper-login-profile-directory nil)
        (ytm-radio-helper-login-cdp-port 29999)
        (ytm-radio-helper-login-timeout 60))
    (should
     (equal
      (ytm-radio--helper-login-arguments "/tmp/ytm-auth.json")
      '("auth"
        "login-window"
        "--output"
        "/tmp/ytm-auth.json"
        "--port"
        "29999"
        "--timeout-secs"
        "60")))))

(ert-deftest ytm-radio-helper-login-profile-default-is-helper-managed ()
  "Leave default account login profile selection to the helper."
  (should-not ytm-radio-helper-login-profile-directory))

(ert-deftest ytm-radio-helper-login-arguments-restart-running ()
  "Pass --restart-running only for confirmed browser restart retries."
  (let ((ytm-radio-helper-login-browser nil)
        (ytm-radio-helper-login-profile-directory nil)
        (ytm-radio-helper-login-cdp-port 29999)
        (ytm-radio-helper-login-timeout 60))
    (should
     (member "--restart-running"
             (ytm-radio--helper-login-arguments "/tmp/ytm-auth.json" t)))))

(ert-deftest ytm-radio-browser-login-detects-restartable-error-code ()
  "Detect the stable helper error code that permits browser restart."
  (should
   (ytm-radio--login-restart-needed-p
    '((code . "browser-restart-required")
      (message . "Zen is already running without WebDriver BiDi"))))
  (should-not
   (ytm-radio--login-restart-needed-p
    '((code . "helper-failure")
      (message . "login window is not authenticated yet")))))

(ert-deftest ytm-radio-account-login-uses-default-auth-file-without-prompt ()
  "Start account login with the configured auth file without prompting."
  (let ((ytm-radio--login-process nil)
        (ytm-radio-helper-auth-file "/tmp/ytm-auth.json")
        captured-output
        captured-continuation
        captured-restart)
    (cl-letf (((symbol-function 'read-file-name)
               (lambda (&rest _arguments)
                 (error "account login prompted for a file")))
              ((symbol-function 'ytm-radio--start-login)
               (lambda (output &optional restart-running after-success)
                 (setq captured-output output
                       captured-restart restart-running
                       captured-continuation after-success))))
      (ytm-radio--start-account-login #'ignore)
      (should (equal captured-output "/tmp/ytm-auth.json"))
      (should-not captured-restart)
      (should (functionp captured-continuation)))))

(ert-deftest ytm-radio-account-login-running-updates-continuation ()
  "Refresh during login should keep one helper process and update continuation."
  (let ((ytm-radio--login-process 'fake-process)
        (ytm-radio--login-continuation nil)
        (ytm-radio--login-status nil)
        (called-start-login nil))
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (process)
                 (eq process 'fake-process)))
              ((symbol-function 'ytm-radio--start-login)
               (lambda (&rest _arguments)
                 (setq called-start-login t)))
              ((symbol-function 'message)
               (lambda (&rest _arguments) nil)))
      (ytm-radio--start-account-login #'ignore "YouTube Music login required")
      (should-not called-start-login)
      (should (functionp ytm-radio--login-continuation))
      (should (equal ytm-radio--login-status "Login waiting in browser...")))))

(ert-deftest ytm-radio-browser-login-runs-continuation-after-success ()
  "Run the pending account action after login imports auth."
  (let ((ytm-radio--state (ytm-radio--make-state))
        (ytm-radio--loaded t)
        (ytm-radio--login-process nil)
        (ytm-radio--login-continuation nil)
        (ytm-radio--login-status nil)
        (ytm-radio-helper-auth-file "/tmp/ytm-auth.json")
        ran-continuation
        started-home)
    (cl-letf (((symbol-function 'ytm-radio--call-helper-async)
               (lambda (_arguments success _error-callback)
                 (funcall success '((auth . t)))
                 nil))
              ((symbol-function 'ytm-radio--save)
               (lambda () nil))
              ((symbol-function 'ytm-radio--start-home-load)
               (lambda (&optional _append)
                 (setq started-home t))))
      (ytm-radio--start-login
       "/tmp/ytm-auth.json"
       nil
       (lambda ()
         (setq ran-continuation t)))
      (should ran-continuation)
      (should-not started-home)
      (should-not ytm-radio--login-status)
      (should-not ytm-radio--login-continuation))))

(ert-deftest ytm-radio-account-auth-failure-starts-login ()
  "Treat structured auth errors as a prompt to refresh account auth."
  (let* ((auth-file (make-temp-file "ytm-radio-auth-"))
         (ytm-radio-helper-auth-file auth-file)
         (ytm-radio--login-process nil)
         captured-continuation)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'ytm-radio--start-login)
                     (lambda (_output &optional _restart-running after-success)
                       (setq captured-continuation after-success))))
            (ytm-radio--handle-account-helper-error
             '((code . "auth-required")
               (message . "YouTube Music returned HTTP 401 Unauthorized")
               (retryable . nil)
               (auth-required . t))
             #'ignore)
            (should-not (file-exists-p auth-file))
            (should (functionp captured-continuation))))
      (when (file-exists-p auth-file)
        (delete-file auth-file)))))

(ert-deftest ytm-radio-helper-refresh-arguments-bypass-response-cache ()
  "Ask the helper to own cache invalidation for explicit refreshes."
  (let ((ytm-radio-helper-auth-file "/tmp/ytm-auth.json"))
    (should (member "--fresh"
                    (ytm-radio--helper-browse-arguments "home" t t)))
    (should-not (member "--fresh"
                        (ytm-radio--helper-browse-arguments "home" t nil)))))

(ert-deftest ytm-radio-helper-process-error-reads-structured-envelope ()
  "Read stable helper error fields instead of matching diagnostic text."
  (with-temp-buffer
    (insert
     (json-serialize
      `((ok . :false)
        (schema . ,ytm-radio--helper-schema-version)
        (protocol . ,ytm-radio--helper-protocol-version)
        (helper-version . ,ytm-radio--helper-version)
        (error . ((code . "network")
                  (message . "request failed")
                  (retryable . t)
                  (auth-required . :false)))
        (warnings . []))))
    (let ((helper-error
           (ytm-radio--helper-process-error (current-buffer) "fallback")))
      (should (equal (map-elt helper-error 'code) "network"))
      (should (map-elt helper-error 'retryable))
      (should-not (map-elt helper-error 'auth-required)))))

(ert-deftest ytm-radio-helper-envelope-validates-schema ()
  "Return helper data only for the supported helper contract."
  (should
   (equal
    (ytm-radio--helper-envelope-data
     `((ok . t)
       (schema . ,ytm-radio--helper-schema-version)
       (protocol . ,ytm-radio--helper-protocol-version)
       (helper-version . ,ytm-radio--helper-version)
       (data . ((sources . nil)))))
    '((sources . nil))))
  (should-error
   (ytm-radio--helper-envelope-data
    `((ok . t)
      (schema . 2)
      (protocol . ,ytm-radio--helper-protocol-version)
      (helper-version . ,ytm-radio--helper-version)
      (data . ((sources . nil)))))
   :type 'user-error)
  (should-error
   (ytm-radio--helper-envelope-data
    `((ok . t)
      (schema . ,ytm-radio--helper-schema-version)
      (protocol . 0)
      (helper-version . ,ytm-radio--helper-version)
      (data . ((sources . nil)))))
   :type 'user-error)
  (should-error
   (ytm-radio--helper-envelope-data
    `((ok . t)
      (schema . ,ytm-radio--helper-schema-version)
      (protocol . ,ytm-radio--helper-protocol-version)
      (helper-version . "0.0.0")
      (data . ((sources . nil)))))
   :type 'user-error))

(ert-deftest ytm-radio-source-from-helper-normalizes-tracks ()
  "Normalize helper sources into durable sources."
  (let* ((source (ytm-radio--source-from-helper
                  '((id . "ytmusic-liked-songs")
                    (kind . "youtube-music-liked")
                    (title . "Liked Music")
                    (url . "ytmusic://library/liked")
                    (items . (((type . "track")
                               (id . "v1")
                               (title . "Song")
                               (url . "https://music.youtube.com/watch?v=v1")
                               (duration . 210)
                               (artist . "Artist")
                               (album . "Album")
                              (thumbnail-url . "thumb.jpg"))
                              ((type . "playlist")
                               (id . "p1")
                               (title . "Playlist")
                               (url . "https://music.youtube.com/playlist?list=p1")
                               (subtitle . "Recommended")))))))
         (track (car (map-elt source :tracks))))
    (should (eq (map-elt source :kind) 'youtube-music-liked))
    (should (equal (map-elt source :title) "Liked Music"))
    (should (= (length (map-elt source :items)) 2))
    (should (= (length (map-elt source :tracks)) 1))
    (should (equal (map-elt track :source-id) "ytmusic-liked-songs"))
    (should (eq (map-elt track :source-kind) 'youtube-music-liked))
    (should (equal (map-elt track :title) "Song"))
    (should (equal (map-elt track :thumbnail-url) "thumb.jpg"))))

(ert-deftest ytm-radio-source-from-helper-preserves-known-false-account-state ()
  "Treat helper false account states as known values."
  (let ((source (ytm-radio--source-from-helper
                 '((id . "ytm:browse:UC1:header")
                   (kind . "youtube-music-artist")
                   (title . "Artist")
                   (in-library . nil)
                   (subscribed . nil)))))
    (should (map-elt source :in-library-known))
    (should (map-elt source :subscribed-known))
    (should-not (map-elt source :in-library))
    (should-not (map-elt source :subscribed))))

(ert-deftest ytm-radio-drop-helper-target-sources-removes-home-sections ()
  "Remove stale home helper sources before importing fresh recommendations."
  (let* ((home (ytm-radio--make-source
                :id "ytm:home:1:listen-again"
                :kind 'youtube-music-home-section
                :title "Listen again"))
         (library (ytm-radio--make-source
                   :id "ytm:library:songs"
                   :kind 'youtube-music-library
                   :title "Library Songs"))
         (manual (ytm-radio--make-source
                  :id "manual"
                  :kind 'youtube-playlist
                  :title "Manual"))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt home :id) home)
                          (cons (map-elt library :id) library)
                          (cons (map-elt manual :id) manual)))))
    (ytm-radio--drop-helper-target-sources "home")
    (should-not (assoc "ytm:home:1:listen-again" (ytm-radio--sources)))
    (should (assoc "ytm:library:songs" (ytm-radio--sources)))
    (should (assoc "manual" (ytm-radio--sources)))))

(ert-deftest ytm-radio-drop-account-helper-sources-removes-detail-sources ()
  "Remove all account helper sources while keeping manual URL sources."
  (let* ((home (ytm-radio--make-source
                :id "ytm:home:1:listen-again"
                :kind 'youtube-music-home-section
                :title "Listen again"))
         (search (ytm-radio--make-source
                  :id "ytm:search:30"
                  :kind 'youtube-music-search
                  :title "Search"))
         (detail (ytm-radio--make-source
                  :id "ytm:browse:UC1:header"
                  :kind 'youtube-music-artist
                  :title "Artist"))
         (manual (ytm-radio--make-source
                  :id "PL1"
                  :kind 'youtube-music-playlist
                  :title "Manual"))
         (ytm-radio--account-state-index (make-hash-table :test #'equal))
         (ytm-radio--account-state-owner nil)
         (ytm-radio--track-status-refreshes (make-hash-table :test #'equal))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt home :id) home)
                          (cons (map-elt search :id) search)
                          (cons (map-elt detail :id) detail)
                          (cons (map-elt manual :id) manual)))))
    (ytm-radio--set-account-state 'subscription '("UC1") t)
    (puthash "abc123_DEF4" (float-time) ytm-radio--track-status-refreshes)
    (ytm-radio--drop-account-helper-sources)
    (should-not (assoc "ytm:home:1:listen-again" (ytm-radio--sources)))
    (should-not (assoc "ytm:search:30" (ytm-radio--sources)))
    (should-not (assoc "ytm:browse:UC1:header" (ytm-radio--sources)))
    (should (assoc "PL1" (ytm-radio--sources)))
    (should (eq (ytm-radio--account-state 'subscription '("UC1"))
                ytm-radio--account-state-missing))
    (should-not (gethash "abc123_DEF4" ytm-radio--track-status-refreshes))))

(provide 'ytm-radio-test)

;;; ytm-radio-test.el ends here
