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

(ert-deftest ytm-radio-mpv-arguments-include-ytdl-raw-options ()
  "Build mpv arguments with raw ytdl options."
  (let ((ytm-radio-mpv-extra-args '("--really-quiet"))
        (ytm-radio-mpv-network-cache-args '("--cache=yes"
                                            "--cache-pause=no"
                                            "--demuxer-readahead-secs=60"
                                            "--demuxer-max-bytes=256MiB"))
        (ytm-radio-mpv-ytdl-format "bestaudio/best")
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

(ert-deftest ytm-radio-mpv-extra-args-can-override-cache-defaults ()
  "Place user mpv args after default mpv playback args."
  (let ((ytm-radio-mpv-network-cache-args '("--cache=yes"
                                            "--demuxer-readahead-secs=60"))
        (ytm-radio-mpv-ytdl-format "bestaudio/best")
        (ytm-radio-mpv-extra-args '("--demuxer-readahead-secs=5"
                                    "--ytdl-format=worstaudio/best"))
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
        (ytm-radio-ytdl-raw-options nil))
    (should-not
     (member "--ytdl-format=bestaudio/best"
             (ytm-radio--mpv-arguments "sock" "url")))))

(ert-deftest ytm-radio-playback-url-uses-valid-stream-cache ()
  "Use cached direct stream URLs until they are close to expiry."
  (let* ((ytm-radio--stream-url-cache (make-hash-table :test #'equal))
         (track (ytm-radio--make-track
                 :id "v1"
                 :title "Song"
                 :url "https://music.youtube.com/watch?v=v1"))
         (direct-url "https://rr.example/videoplayback?expire=9999999999"))
    (ytm-radio--cache-stream-url track direct-url)
    (should (equal (ytm-radio--playback-url track) direct-url))
    (puthash "v1"
             (list (cons 'url "https://rr.example/expired")
                   (cons 'expires 1))
             ytm-radio--stream-url-cache)
    (should (equal (ytm-radio--playback-url track)
                   "https://music.youtube.com/watch?v=v1"))))

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
                   :duration 180
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
              ((symbol-function 'ytm-radio--render) #'ignore)
              ((symbol-function 'ytm-radio--show-now-playing) #'ignore)
              ((symbol-function 'ytm-radio--schedule-stream-prefetch)
               (lambda (tracks) (setq scheduled tracks))))
      (ytm-radio--play-track track-a)
      (should (member '("seek" 0 "absolute") commands))
      (should (member '("set_property" "pause" :json-false) commands))
      (should (eq (map-elt ytm-radio--player :status) 'playing))
      (should (= (map-elt ytm-radio--player :position) 0))
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

(ert-deftest ytm-radio-render-explains-empty-catalog ()
  "Render an empty catalog with next-step guidance."
  (let ((ytm-radio--state (ytm-radio--make-state))
        (ytm-radio--player (ytm-radio--make-player))
        (ytm-radio--browser-view 'home))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render)
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

(ert-deftest ytm-radio-render-library-items-are-compact ()
  "Render Library items without secondary detail lines."
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

(ert-deftest ytm-radio-album-playlist-detail-headers-use-square-layout ()
  "Use square detail covers for album and playlist headers only."
  (let ((album (ytm-radio--make-source
                :id "ytm:browse:MPRE1:header"
                :kind 'youtube-music-album
                :title "Album"))
        (playlist (ytm-radio--make-source
                   :id "ytm:browse:VLPL1:header"
                   :kind 'youtube-music-playlist
                   :title "Playlist"))
        (detail (ytm-radio--make-source
                 :id "ytm:browse:detail:header"
                 :kind 'youtube-music-detail
                 :title "Detail")))
    (should (ytm-radio--source-square-header-p album))
    (should (ytm-radio--source-square-header-p playlist))
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
               (lambda (_source) 'placeholder-cover)))
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
              'youtube-music-playlist)))

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

(ert-deftest ytm-radio-artist-detail-header-prefers-banner-image ()
  "Render artist detail headers as a wide banner instead of a square cover."
  (let* ((source (ytm-radio--make-source
                  :id "ytm:browse:UC1:header"
                  :kind 'youtube-music-artist
                  :title "Chill girl Vibes"
                  :url "https://music.youtube.com/browse/UC1"
                  :tracks nil
                  :items nil
                  :subtitle "448K monthly audience"
                  :thumbnail-url "https://example.com/banner.jpg")))
    (with-temp-buffer
      (cl-letf (((symbol-function 'ytm-radio--source-header-banner-image)
                 (lambda (_source _title _subtitle _summary) 'banner-image))
                ((symbol-function 'ytm-radio--source-header-cover-image)
                 (lambda (_source) (list 'cover-image 90 10 3)))
                ((symbol-function 'ytm-radio--detail-view-tracks)
                 (lambda () nil)))
        (ytm-radio--insert-source-header source t))
      (should (string-match-p "Chill girl Vibes" (buffer-string)))
      (should (string-match-p "448K monthly audience" (buffer-string)))
      (goto-char (point-min))
      (should (equal (get-text-property (point) 'display) 'banner-image)))))

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
  (should-not (lookup-key ytm-radio--mode-map (kbd "A")))
  (should (eq (lookup-key ytm-radio--mode-map (kbd "b"))
              #'ytm-radio-back))
  (should-not (eq (lookup-key ytm-radio--mode-map (kbd "h"))
                  #'ytm-radio-home))
  (should-not (eq (lookup-key ytm-radio--mode-map (kbd "e"))
                  #'ytm-radio-explore))
  (should-not (lookup-key ytm-radio--mode-map (kbd "o")))
  (should-not (lookup-key ytm-radio--mode-map (kbd "l"))))

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

(ert-deftest ytm-radio-playback-status-does-not-rerender-browser ()
  "Keep browser content stable when mpv reports play/pause status changes."
  (let ((ytm-radio--player (ytm-radio--make-player :status 'playing))
        (browser-rendered nil)
        (now-playing-rendered nil))
    (cl-letf (((symbol-function 'ytm-radio--render-browser)
               (lambda (&optional _reset-point)
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

(ert-deftest ytm-radio-q-bindings-hide-browser-and-now-playing-separately ()
  "Keep browser quit separate from now-playing child-frame hiding."
  (should (eq (lookup-key ytm-radio--mode-map (kbd "q"))
              #'ytm-radio-hide-browser))
  (should (eq (lookup-key ytm-radio--now-playing-mode-map (kbd "q"))
              #'ytm-radio-hide-now-playing)))

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

(ert-deftest ytm-radio-json-process-ignores-success-stderr ()
  "Parse process stdout JSON while ignoring successful stderr diagnostics."
  (let ((script-file (make-temp-file "ytm-radio-helper-" nil ".sh")))
    (unwind-protect
        (progn
          (with-temp-file script-file
            (insert "#!/bin/sh\n")
            (insert
             "printf '%s\\n' '{\"ok\":true,\"schema\":1,\"data\":{\"sources\":[]},\"warnings\":[]}'\n")
            (insert "printf '%s\\n' 'diagnostic' >&2\n"))
          (set-file-modes script-file #o700)
          (let ((ytm-radio-helper-command script-file))
            (let ((result
                   (ytm-radio--call-json-process
                    ytm-radio-helper-command
                    nil
                    (lambda (diagnostic)
                      (user-error "failed: %s" diagnostic)))))
              (should (equal result
                             '((ok . t)
                               (schema . 1)
                               (data (sources))
                               (warnings)))))))
      (delete-file script-file))))

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
        (ytm-radio-helper-library-limit 25))
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
        (ytm-radio-helper-home-limit 12))
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
        (ytm-radio-helper-home-limit 12))
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
        (ytm-radio-helper-library-limit 25))
    (should (equal (ytm-radio--helper-search-arguments "tokyo")
                   '("search"
                     "tokyo"
                     "--auth"
                     "/tmp/auth.json"
                     "--mock"
                     "--limit"
                     "25")))))

(ert-deftest ytm-radio-helper-browse-id-arguments-include-limit-and-mock ()
  "Build Rust helper arguments for detail browse imports."
  (let ((ytm-radio-helper-auth-file "/tmp/auth.json")
        (ytm-radio-helper-use-mock-data t)
        (ytm-radio-helper-library-limit 25))
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
        (ytm-radio-helper-library-limit 25))
    (should (equal (ytm-radio--helper-browse-id-arguments "VLPL1" "ggMCCAI%3D")
                   '("browse-id"
                     "VLPL1"
                     "--params"
                     "ggMCCAI%3D"
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
        fetched-url)
    (cl-letf (((symbol-function 'ytm-radio--open-browse-id-as-source)
               (lambda (browse-id &optional params context)
                 (setq called-browse-id browse-id)
                 (setq called-params params)
                 (setq called-context context)))
              ((symbol-function 'ytm-radio--open-url-as-source)
               (lambda (url)
                 (setq fetched-url url))))
      (ytm-radio--open-item source item)
      (should (equal called-browse-id "VLPL1"))
      (should-not called-params)
      (should (eq called-context item))
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
      (should (equal ytm-radio--browser-history '(home))))))

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
      (should (equal ytm-radio--browser-history '(home))))))

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
      (should (equal ytm-radio--browser-history '(library))))))

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
        "60"
        "--profile-dir"
        "/tmp/ytm-login-profile"
        "--browser"
        "dia")))))

(ert-deftest ytm-radio-helper-login-arguments-auto-browser ()
  "Omit --browser when the helper should use the default browser."
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
