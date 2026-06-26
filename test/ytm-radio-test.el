;;; ytm-radio-test.el --- Tests for ytm-radio -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'map)
(require 'ytm-radio)

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

(ert-deftest ytm-radio-add-url-imports-asynchronously ()
  "Add URLs through async yt-dlp import without blocking."
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
         played-source)
    (cl-letf (((symbol-function 'ytm-radio--fetch-source-async)
               (lambda (url success _error-callback)
                 (setq imported-url url)
                 (setq import-success success)
                 'process))
              ((symbol-function 'ytm-radio--save) #'ignore)
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
      (should (equal (map-elt (cdr (assoc "src" (ytm-radio--sources))) :title)
                     "Source"))
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
                     "--really-quiet"
                     "--ytdl-raw-options=cookies-from-browser=chrome,proxy=http://127.0.0.1:8888"
                     "--no-video"
                     "--input-ipc-server=sock"
                     "url")))))

(ert-deftest ytm-radio-mpv-extra-args-can-override-cache-defaults ()
  "Place user mpv args after default mpv playback args."
  (let ((ytm-radio-mpv-network-cache-args '("--cache=yes"
                                            "--demuxer-readahead-secs=60"))
        (ytm-radio-mpv-ytdl-format "bestaudio/best")
        (ytm-radio-mpv-extra-args '("--demuxer-readahead-secs=5"
                                    "--ytdl-format=worstaudio/best"))
        (ytm-radio-proxy-url nil)
        (ytm-radio-ytdl-raw-options nil))
    (should (equal (seq-take (ytm-radio--mpv-arguments "sock" "url") 5)
                   '("--cache=yes"
                     "--demuxer-readahead-secs=60"
                     "--ytdl-format=bestaudio/best"
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
      (should (eq (map-elt ytm-radio--player :status) 'loading))
      (should-not (map-elt ytm-radio--player :using-stream-cache))
      (should (map-elt ytm-radio--player :retried-original-url)))))

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
      (should (map-elt ytm-radio--player :retried-playback-error))
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
               (lambda ()
                 (setq stopped-preserve
                       ytm-radio--preserve-playback-retry-state)))
              ((symbol-function 'ytm-radio--play-track)
               (lambda (track) (setq retried-track track)))
              ((symbol-function 'message) #'ignore))
      (ytm-radio--mpv-event
       "end-file"
       '((reason . "error")
         (file_error . "no audio or video data played")))
      (should (equal retried-track track))
      (should stopped-preserve)
      (should (map-elt ytm-radio--player :retried-playback-error))
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
               (lambda () (setq stopped t)))
              ((symbol-function 'ytm-radio--play-track)
               (lambda (track) (setq retried-track track)))
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
               (lambda (track) (setq retried-track track)))
              ((symbol-function 'message) #'ignore))
      (ytm-radio--mpv-sentinel 'mpv-process "exited")
      (should (equal retried-track track))
      (should (map-elt ytm-radio--player :retried-playback-error)))))

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
           :sources (list (cons (map-elt stale-home :id) stale-home))))
        (ytm-radio--player (ytm-radio--make-player))
        (ytm-radio--loaded t)
        (ytm-radio--browser-view 'home)
        (ytm-radio--initial-home-refreshed nil)
        (ytm-radio-helper-use-mock-data nil)
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

(ert-deftest ytm-radio-opens-with-home-import-when-auth-exists-and-no-cache ()
  "Refresh Home on first browser open when account auth is available and uncached."
  (let ((ytm-radio--state (ytm-radio--make-state))
        (ytm-radio--player (ytm-radio--make-player))
        (ytm-radio--loaded t)
        (ytm-radio--browser-view 'home)
        (ytm-radio--initial-home-refreshed nil)
        (ytm-radio-helper-use-mock-data nil)
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
         (ytm-radio-helper-use-mock-data nil)
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
           :sources (list (cons (map-elt source :id) source))))
         (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render)
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p "YouTube Music Home" (buffer-string)))
      (should (string-match-p "01[[:space:]]+Album Title"
                              (buffer-string)))
      (should (string-match-p "Album Title[^\n]*\n[[:space:]]+ALBM[[:space:]]+Artist"
                              (buffer-string)))
      (goto-char (point-min))
      (search-forward "Album Title")
      (should (eq (button-get (button-at (match-beginning 0)) 'face)
                  'ytm-radio-item-title)))))

(ert-deftest ytm-radio-render-track-rating-indicators ()
  "Render liked and disliked markers after track titles."
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
      (should (string-match-p (regexp-quote "Liked Song ▲")
                              (buffer-string)))
      (should (string-match-p (regexp-quote "Disliked Song ▼")
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
  "Render Library items without secondary detail lines or redundant markers."
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
    (ytm-radio--render)
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p "01[[:space:]]+Let Her Go"
                              (buffer-string)))
      (should-not (string-match-p
                   "Songs[[:space:]]+Albums[[:space:]]+Artists"
                   (buffer-string)))
      (should-not (string-match-p "Passenger - All The Little Lights"
                                  (buffer-string)))
      (should-not (string-match-p (regexp-quote "Let Her Go ▲")
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
         (ytm-radio--home-continuation "next-page")
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
      (should-not
       (string-match-p "Load more Home sections" (buffer-string))))))

(ert-deftest ytm-radio-home-lazy-load-starts-near-buffer-end ()
  "Start Home continuation loading when the visible window reaches the end."
  (let ((ytm-radio--browser-view 'home)
        (ytm-radio--home-continuation "next-page")
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
        (ytm-radio--home-continuation nil)
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
      (should (equal ytm-radio--home-continuation "next-page"))
      (ytm-radio--apply-home-helper-data next t)
      (should (assoc "ytm:home:listen" (ytm-radio--sources)))
      (should (assoc "ytm:home:mixed" (ytm-radio--sources)))
      (should-not ytm-radio--home-continuation))))

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
         (ytm-radio-helper-use-mock-data t)
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
    (cl-letf (((symbol-function 'ytm-radio--call-helper-async)
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
                     '("search" "30" "--mock" "--limit" "12")))
      (should (eq (ytm-radio--view-kind) 'search))
      (should (ytm-radio--source "ytm:search:30:1:songs"))
      (should-not ytm-radio--browser-load-process)
      (should-not ytm-radio--browser-loading-message))))

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

(ert-deftest ytm-radio-refresh-liked-section-reloads-helper-target ()
  "Refreshing a liked songs section clears cached helper data and reloads it."
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
         (clear-count 0)
         captured)
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--clear-helper-response-cache)
               (lambda () (cl-incf clear-count)))
              ((symbol-function 'ytm-radio--start-helper-target-load)
               (lambda (target label loading-view &optional restore-entry)
                 (setq captured
                       (list target label loading-view
                             (map-elt restore-entry :view))))))
      (ytm-radio-refresh)
      (should (= clear-count 1))
      (should (equal captured
                     (list "liked" "liked songs" view view))))))

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

(ert-deftest ytm-radio-browse-detail-header-prefers-source-subscription-state ()
  "Do not let stale opener context override helper subscription state."
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
         (unsubscribed-source
          (ytm-radio--make-source
           :id "ytm:browse:UC2"
           :kind 'youtube-music-artist
           :title "Artist"
           :url "https://music.youtube.com/browse/UC2"
           :items nil
           :tracks nil
           :subscribed nil
           :subscribed-known t))
         (stale-subscribed-item
          '((type . "artist")
            (title . "Artist")
            (browse-id . "UC2")
            (subscribed . t)))
         (unsubscribed-header
          (car (ytm-radio--browse-detail-sources
                (list unsubscribed-source)
                stale-subscribed-item))))
    (should (map-elt subscribed-header :subscribed))
    (should-not (map-elt unsubscribed-header :subscribed))
    (should (map-elt unsubscribed-header :subscribed-known))))

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
  (let ((ytm-radio--player (ytm-radio--make-player :status 'idle))
        (process (make-process
                  :name "ytm-radio-test-filter"
                  :buffer nil
                  :command '("true")
                  :noquery t)))
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

(ert-deftest ytm-radio-render-now-playing-gaps-cover-and-title ()
  "Insert thin padding between the cover and title."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"))
        (ytm-radio--player (ytm-radio--make-player)))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--cover-spec)
               (lambda (_track) nil))
              ((symbol-function 'ytm-radio--now-playing-visible-p)
               (lambda () nil)))
      (ytm-radio--render-now-playing))
    (with-current-buffer "*ytm-radio-now-playing*"
      (goto-char (point-min))
      (search-forward "[cover]\n")
      (should (equal (get-text-property (point) 'display)
                     '((height 0.25)))))))

(ert-deftest ytm-radio-render-now-playing-uses-larger-edge-padding ()
  "Give now-playing top and bottom edges a little more padding."
  (let ((track (ytm-radio--make-track
                :id "v1"
                :title "Song"
                :url "https://music.youtube.com/watch?v=v1"))
        (ytm-radio--player (ytm-radio--make-player)))
    (setf (map-elt ytm-radio--player :current-track) track)
    (with-current-buffer (ytm-radio--now-playing-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--cover-spec)
               (lambda (_track) nil))
              ((symbol-function 'ytm-radio--now-playing-visible-p)
               (lambda () nil)))
      (ytm-radio--render-now-playing))
    (with-current-buffer "*ytm-radio-now-playing*"
      (goto-char (point-min))
      (should (equal (get-text-property (point) 'display)
                     '((height 0.5))))
      (goto-char (point-max))
      (forward-line -1)
      (should (equal (get-text-property (point) 'display)
                     '((height 0.5)))))))

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
  "Expose current-track actions from browser and now-playing buffers."
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
  (should (eq (lookup-key ytm-radio--now-playing-mode-map (kbd "A"))
              #'ytm-radio-current-actions))
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
         (ytm-radio-helper-use-mock-data nil)
         called-arguments
         (clear-count 0))
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success
                          '((video-id . "abc123_DEF4") (rating . "like")))))
              ((symbol-function 'ytm-radio--clear-helper-response-cache)
               (lambda () (cl-incf clear-count)))
              ((symbol-function 'ytm-radio--render-now-playing) #'ignore)
              ((symbol-function 'ytm-radio--render-browser) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-like-current-track)
      (should (equal called-arguments '("rate" "abc123_DEF4" "like")))
      (should (eq (map-elt track :like-status) 'like))
      (ytm-radio-like-current-track)
      (should (equal called-arguments '("rate" "abc123_DEF4" "indifferent")))
      (should-not (map-elt track :like-status))
      (should (= clear-count 2)))))

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

(ert-deftest ytm-radio-set-track-like-status-syncs-source-items ()
  "Propagate local rating changes to cached source tracks and raw items."
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
      (should (eq (map-elt track :like-status) 'like))
      (should (eq (map-elt source-track :like-status) 'like))
      (should (equal (map-elt item 'like-status) "like"))
      (should now-playing-rendered)
      (should browser-rendered)
      (ytm-radio--set-track-like-status track nil)
      (should-not (map-elt track :like-status))
      (should-not (map-elt source-track :like-status))
      (should-not (map-elt item 'like-status)))))

(ert-deftest ytm-radio-refresh-track-status-applies-helper-data ()
  "Refresh current track account status through the helper without prompting."
  (let* ((track (ytm-radio--make-track
                 :id "local-id"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=abc123_DEF4"))
         (ytm-radio--track-status-refreshes (make-hash-table :test #'equal))
         (ytm-radio--player (ytm-radio--make-player :current-track track))
         (ytm-radio-helper-auth-file nil)
         (ytm-radio-helper-use-mock-data nil)
         called-arguments
         now-playing-rendered)
    (cl-letf (((symbol-function 'ytm-radio--track-status-refresh-available-p)
               (lambda () t))
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success '((video-id . "abc123_DEF4")
                                    (in-library . t)
                                    (like-status . "like")))))
              ((symbol-function 'ytm-radio--render-now-playing)
               (lambda () (setq now-playing-rendered t)))
              ((symbol-function 'ytm-radio--render-browser) #'ignore))
      (ytm-radio--refresh-track-status track)
      (should (equal called-arguments '("track-status" "abc123_DEF4")))
      (should (eq (map-elt track :like-status) 'like))
      (should (map-elt track :in-library))
      (should now-playing-rendered)
      (should (eq (gethash "abc123_DEF4" ytm-radio--track-status-refreshes)
                  'done)))))

(ert-deftest ytm-radio-toggle-current-track-library-calls-helper ()
  "Toggle library status for the current track through the helper."
  (let* ((track (ytm-radio--make-track
                 :id "local-id"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=abc123_DEF4"))
         (ytm-radio--player (ytm-radio--make-player :current-track track))
         (ytm-radio-helper-auth-file nil)
         (ytm-radio-helper-use-mock-data nil)
         called-arguments
         (clear-count 0))
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
              ((symbol-function 'ytm-radio--clear-helper-response-cache)
               (lambda () (cl-incf clear-count)))
              ((symbol-function 'ytm-radio--render-now-playing) #'ignore)
              ((symbol-function 'ytm-radio--render-browser) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-toggle-current-track-library)
      (should (equal called-arguments '("library" "abc123_DEF4" "toggle")))
      (should (map-elt track :in-library))
      (should (eq (map-elt track :like-status) 'like))
      (should (= clear-count 1)))))

(ert-deftest ytm-radio-toggle-detail-library-syncs-source-items ()
  "Toggle detail library status and update matching cached items."
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
         (ytm-radio-helper-use-mock-data nil)
         called-arguments
         (clear-count 0)
         rendered)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success '((browse-id . "VLPL1")
                                    (in-library . t)
                                    (changed . t)))))
              ((symbol-function 'ytm-radio--clear-helper-response-cache)
               (lambda () (cl-incf clear-count)))
              ((symbol-function 'ytm-radio--render-browser)
               (lambda (&rest _args) (setq rendered t)))
              ((symbol-function 'message) #'ignore))
      (ytm-radio-toggle-detail-library)
      (should (equal called-arguments
                     '("item-library" "VLPL1" "save"
                       "--params" "ggMCCAI%3D")))
      (should (map-elt detail-source :in-library))
      (should (map-elt item 'in-library))
      (should (= clear-count 1))
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
         (ytm-radio-helper-use-mock-data nil)
         called-arguments)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success '((browse-id . "MPRE1")
                                    (in-library . nil)
                                    (changed . t)))))
              ((symbol-function 'ytm-radio--clear-helper-response-cache) #'ignore)
              ((symbol-function 'ytm-radio--render-browser) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-toggle-detail-library)
      (should (equal called-arguments
                     '("item-library" "MPRE1" "remove")))
      (should-not (map-elt detail-source :in-library))
      (should-not (map-elt item 'in-library)))))

(ert-deftest ytm-radio-toggle-detail-subscription-syncs-source-items ()
  "Toggle detail subscription status and update matching cached items."
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
         (ytm-radio-helper-use-mock-data nil)
         called-arguments)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success '((browse-id . "UC1")
                                    (subscribed . t)
                                    (changed . t)))))
              ((symbol-function 'ytm-radio--clear-helper-response-cache) #'ignore)
              ((symbol-function 'ytm-radio--render-browser) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-toggle-detail-subscription)
      (should (equal called-arguments
                     '("subscription" "UC1" "subscribe")))
      (should (map-elt detail-source :subscribed))
      (should (map-elt item 'subscribed)))))

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
         (ytm-radio-helper-use-mock-data nil)
         called-arguments)
    (cl-letf (((symbol-function 'ytm-radio--with-account-auth)
               (lambda (action &optional _message)
                 (funcall action)))
              ((symbol-function 'ytm-radio--ensure-loaded) #'ignore)
              ((symbol-function 'ytm-radio--call-helper-async)
               (lambda (arguments success _error-callback)
                 (setq called-arguments arguments)
                 (funcall success '((browse-id . "UC1")
                                    (subscribed . nil)
                                    (changed . t)))))
              ((symbol-function 'ytm-radio--clear-helper-response-cache) #'ignore)
              ((symbol-function 'ytm-radio--render-browser) #'ignore)
              ((symbol-function 'message) #'ignore))
      (ytm-radio-toggle-detail-subscription)
      (should (equal called-arguments
                     '("subscription" "UC1" "unsubscribe")))
      (should-not (map-elt detail-source :subscribed))
      (should (map-elt detail-source :subscribed-known)))))

(ert-deftest ytm-radio-sync-browse-account-state-updates-channel-sources ()
  "Update cached channel detail sources after subscription changes."
  (let* ((channel-source (ytm-radio--make-source
                          :id "ytm:channel:UC1:header"
                          :kind 'youtube-channel
                          :title "Channel"
                          :url "https://music.youtube.com/browse/UC1"))
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt channel-source :id) channel-source)))))
    (ytm-radio--sync-browse-account-state "UC1" :subscribed 'subscribed t)
    (should (map-elt channel-source :subscribed))))

(ert-deftest ytm-radio-start-current-track-mix-sets-runtime-queue ()
  "Start mix by loading helper tracks into the runtime queue."
  (let* ((track (ytm-radio--make-track
                 :id "local-id"
                 :title "Seed"
                 :url "https://music.youtube.com/watch?v=abc123_DEF4"))
         (ytm-radio--player (ytm-radio--make-player :current-track track))
         (ytm-radio-helper-auth-file nil)
         (ytm-radio-helper-use-mock-data nil)
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
         (ytm-radio-helper-use-mock-data nil)
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
         (ytm-radio-helper-auth-file auth-file)
         (ytm-radio-helper-use-mock-data nil))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\n"))
          (set-file-modes program #o700)
          (with-temp-file auth-file
            (insert "{}"))
          (let ((report (ytm-radio--doctor-report)))
            (should (string-match-p "^helper[[:space:]]+OK" report))
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
                   "ytm-radio-helper-x86_64-unknown-linux-gnu"))))

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
        (focus-count 0))
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
                   (cl-incf focus-count))))
        (should (eq (ytm-radio--show-child-frame (current-buffer)) 'frame))
        (should (= visible-count 0))
        (should (= focus-count 0))))))

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

(ert-deftest ytm-radio-helper-browse-arguments-include-limit-and-mock ()
  "Build Rust helper arguments for library imports."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-use-mock-data t)
        (ytm-radio-helper-library-limit 25)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-browse-arguments "library")
                   '("browse"
                     "library"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock"
                     "--limit"
                     "25")))))

(ert-deftest ytm-radio-helper-home-initial-arguments-include-initial-only ()
  "Build Rust helper arguments for non-blocking Home imports."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-use-mock-data t)
        (ytm-radio-helper-home-limit 12)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-browse-arguments "home" t)
                   '("browse"
                     "home"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock"
                     "--initial-only"
                     "--limit"
                     "12")))))

(ert-deftest ytm-radio-helper-continuation-arguments-include-limit-and-mock ()
  "Build Rust helper arguments for Home continuation imports."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-use-mock-data t)
        (ytm-radio-helper-home-limit 12)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-continuation-arguments "next-page")
                   '("continuation"
                     "next-page"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock"
                     "--limit"
                     "12")))))

(ert-deftest ytm-radio-helper-search-arguments-include-limit-and-mock ()
  "Build Rust helper arguments for search imports."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-use-mock-data t)
        (ytm-radio-helper-library-limit 25)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-search-arguments "tokyo")
                   '("search"
                     "tokyo"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock"
                     "--limit"
                     "25")))))

(ert-deftest ytm-radio-helper-rate-arguments-include-auth-and-mock ()
  "Build Rust helper arguments for rating tracks."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-use-mock-data t)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-rate-arguments "v1" "like")
                   '("rate"
                     "v1"
                     "like"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock")))))

(ert-deftest ytm-radio-helper-track-status-arguments-include-auth-and-mock ()
  "Build Rust helper arguments for track account status."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-use-mock-data t)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-track-status-arguments "v1")
                   '("track-status"
                     "v1"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock")))))

(ert-deftest ytm-radio-helper-current-action-arguments-include-auth-and-mock ()
  "Build Rust helper arguments for current-track actions."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-use-mock-data t)
        (ytm-radio-helper-library-limit 25)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-radio-arguments "v1")
                   '("radio"
                     "v1"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock"
                     "--limit"
                     "25")))
    (should (equal (ytm-radio--helper-playlist-options-arguments "v1")
                   '("playlist-options"
                     "v1"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock")))
    (should (equal (ytm-radio--helper-add-to-playlist-arguments "v1" "pl1")
                   '("add-to-playlist"
                     "v1"
                     "pl1"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock")))
    (should (equal (ytm-radio--helper-library-arguments "v1" "toggle")
                   '("library"
                     "v1"
                     "toggle"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock")))
    (should (equal (ytm-radio--helper-item-library-arguments
                    "VLPL1" "toggle" "ggMCCAI%3D")
                   '("item-library"
                     "VLPL1"
                     "toggle"
                     "--params"
                     "ggMCCAI%3D"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock")))
    (should (equal (ytm-radio--helper-subscription-arguments
                    "UC1" "toggle" nil)
                   '("subscription"
                     "UC1"
                     "toggle"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock")))))

(ert-deftest ytm-radio-helper-browse-id-arguments-include-limit-and-mock ()
  "Build Rust helper arguments for detail browse imports."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-use-mock-data t)
        (ytm-radio-helper-library-limit 25)
        (ytm-radio-proxy-url nil))
    (should (equal (ytm-radio--helper-browse-id-arguments "VLPL1")
                   '("browse-id"
                     "VLPL1"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock"
                     "--limit"
                     "25")))))

(ert-deftest ytm-radio-helper-browse-id-arguments-include-params ()
  "Pass YouTube Music browse endpoint params to the helper."
  (let ((ytm-radio-helper-auth-file nil)
        (ytm-radio-helper-use-mock-data nil)
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
        (ytm-radio-helper-use-mock-data nil)
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
         (ytm-radio-helper-use-mock-data t)
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--loaded t)
         (ytm-radio--browser-view 'home)
         (ytm-radio--browser-history nil)
         (ytm-radio--browser-load-process nil))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--call-helper-async)
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
         (ytm-radio-helper-use-mock-data t)
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--loaded t)
         (ytm-radio--browser-view 'home)
         (ytm-radio--browser-history nil)
         (ytm-radio--browser-load-process nil))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--call-helper-async)
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
         (ytm-radio-helper-use-mock-data t)
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
      (cl-letf (((symbol-function 'ytm-radio--call-helper-async)
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
         (ytm-radio-helper-use-mock-data t)
         (ytm-radio--state (ytm-radio--make-state))
         (ytm-radio--player (ytm-radio--make-player))
         (ytm-radio--loaded t)
         (ytm-radio--browser-view 'library)
         (ytm-radio--browser-history nil)
         (ytm-radio--browser-load-process nil))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (cl-letf (((symbol-function 'ytm-radio--call-helper-async)
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

(ert-deftest ytm-radio-browser-login-detects-restartable-diagnostics ()
  "Detect helper diagnostics that can be handled by browser restart."
  (should
   (ytm-radio--login-restart-needed-p
    "Dia is already running without DevTools on 127.0.0.1:29317"))
  (should-not
   (ytm-radio--login-restart-needed-p
    "login window is not authenticated yet")))

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
  "Treat 401 helper diagnostics as a prompt to refresh account auth."
  (let* ((auth-file (make-temp-file "ytm-radio-auth-"))
         (ytm-radio-helper-use-mock-data nil)
         (ytm-radio-helper-auth-file auth-file)
         (ytm-radio--login-process nil)
         captured-continuation)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'ytm-radio--start-login)
                     (lambda (_output &optional _restart-running after-success)
                       (setq captured-continuation after-success))))
            (ytm-radio--with-account-auth
             (lambda ()
               (user-error
                "Account helper failed: YouTube Music returned HTTP 401 Unauthorized")))
            (should-not (file-exists-p auth-file))
            (should (functionp captured-continuation))))
      (when (file-exists-p auth-file)
        (delete-file auth-file)))))

(ert-deftest ytm-radio-clear-helper-bootstrap-cache ()
  "Delete helper caches beside the configured auth file."
  (let* ((directory (make-temp-file "ytm-radio-auth-" t))
         (ytm-radio-helper-auth-file
          (expand-file-name "auth.json" directory))
         (cache-file (expand-file-name "bootstrap-cache.json" directory))
         (response-cache (expand-file-name "response-cache" directory)))
    (unwind-protect
        (progn
          (with-temp-file cache-file
            (insert "{}"))
          (make-directory response-cache)
          (with-temp-file (expand-file-name "entry.json" response-cache)
            (insert "{}"))
          (ytm-radio--clear-helper-bootstrap-cache)
          (should-not (file-exists-p cache-file))
          (should-not (file-exists-p response-cache)))
      (delete-directory directory t))))

(ert-deftest ytm-radio-helper-envelope-validates-schema ()
  "Return helper data only for successful schema version one envelopes."
  (should
   (equal
    (ytm-radio--helper-envelope-data
     '((ok . t)
       (schema . 1)
       (data . ((sources . nil)))))
    '((sources . nil))))
  (should-error
   (ytm-radio--helper-envelope-data
    '((ok . t)
      (schema . 2)
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
         (ytm-radio--state
          (ytm-radio--make-state
           :sources (list (cons (map-elt home :id) home)
                          (cons (map-elt search :id) search)
                          (cons (map-elt detail :id) detail)
                          (cons (map-elt manual :id) manual)))))
    (ytm-radio--drop-account-helper-sources)
    (should-not (assoc "ytm:home:1:listen-again" (ytm-radio--sources)))
    (should-not (assoc "ytm:search:30" (ytm-radio--sources)))
    (should-not (assoc "ytm:browse:UC1:header" (ytm-radio--sources)))
    (should (assoc "PL1" (ytm-radio--sources)))))

(provide 'ytm-radio-test)

;;; ytm-radio-test.el ends here
