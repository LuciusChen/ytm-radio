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
        (ytm-radio-ytdl-raw-options '("cookies-from-browser=chrome"
                                      "proxy=http://127.0.0.1:8888")))
    (should (equal (ytm-radio--mpv-arguments "sock" "url")
                   '("--really-quiet"
                     "--ytdl-raw-options=cookies-from-browser=chrome,proxy=http://127.0.0.1:8888"
                     "--no-video"
                     "--input-ipc-server=sock"
                     "url")))))

(ert-deftest ytm-radio-render-explains-empty-catalog ()
  "Render an empty catalog with next-step guidance."
  (let ((ytm-radio--state (ytm-radio--make-state))
        (ytm-radio--player (ytm-radio--make-player)))
    (with-current-buffer (ytm-radio--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (ytm-radio--render)
    (with-current-buffer "*ytm-radio*"
      (should (string-match-p
               "Add a URL, or import your YouTube Music library/home"
               (buffer-string)))
      (should (string-match-p
               "Use login once to import a browser session"
               (buffer-string))))))

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
                            (url . "https://music.youtube.com/browse/MPRE1")))))
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
      (should (string-match-p "album" (buffer-string)))
      (should (string-match-p "Album Title" (buffer-string)))
      (should (string-match-p "Artist" (buffer-string))))))

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
               (regexp-quote "0:42  ━━●━━━━━━━  3:05")
               (buffer-string)))
      (should (string-match-p "<<" (buffer-string)))
      (should (string-match-p "||" (buffer-string)))
      (should (string-match-p ">>" (buffer-string)))
      (goto-char (point-min))
      (search-forward "||")
      (should (button-at (1- (point)))))))

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
      (should-not (string-match-p "||" (buffer-string))))))

(ert-deftest ytm-radio-progress-position-refresh-is-throttled ()
  "Throttle frequent position changes instead of rendering each update."
  (let ((ytm-radio--progress-render-timer nil)
        (render-count 0))
    (cl-letf (((symbol-function 'ytm-radio--render-now-playing)
               (lambda ()
                 (cl-incf render-count))))
      (unwind-protect
          (progn
            (ytm-radio--set-playback-property :position 1)
            (ytm-radio--set-playback-property :position 2)
            (should (= render-count 0))
            (should (timerp ytm-radio--progress-render-timer)))
        (ytm-radio--cancel-progress-render)))))

(ert-deftest ytm-radio-helper-json-ignores-success-stderr ()
  "Parse helper stdout JSON while ignoring successful stderr diagnostics."
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
            (should
             (equal
              (ytm-radio--helper-envelope-data
               (ytm-radio--call-helper nil))
              '((sources . nil))))))
      (delete-file script-file))))

(ert-deftest ytm-radio-progress-bar-renders-unicode ()
  "Render compact Unicode progress bars."
  (should (equal (substring-no-properties
                  (ytm-radio--progress-bar nil 185 10))
                 "●━━━━━━━━━"))
  (should (equal (substring-no-properties
                  (ytm-radio--progress-bar 42 185 10))
                 "━━●━━━━━━━"))
  (should (equal (substring-no-properties
                  (ytm-radio--progress-bar 185 185 10))
                 "━━━━━━━━━●")))

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

(ert-deftest ytm-radio-helper-browser-import-arguments ()
  "Build Rust helper arguments for browser cookie import."
  (let ((ytm-radio-yt-dlp-program "/opt/homebrew/bin/yt-dlp"))
    (should
     (equal
      (ytm-radio--helper-import-browser-arguments
       "chrome:Default"
       "/tmp/ytm-auth.json")
      '("auth"
        "import-browser"
        "--browser"
        "chrome:Default"
        "--output"
        "/tmp/ytm-auth.json"
        "--yt-dlp"
        "/opt/homebrew/bin/yt-dlp")))))

(ert-deftest ytm-radio-auth-import-candidates-include-dia ()
  "Offer Dia through the unified login source prompt."
  (let ((ytm-radio-helper-browser-candidates '("chrome" "firefox")))
    (should (equal (ytm-radio--auth-import-candidates)
                   '("chrome" "firefox" "dia")))
    (should (ytm-radio--dia-auth-source-p "dia"))
    (should (ytm-radio--dia-auth-source-p " Dia "))
    (should-not (ytm-radio--dia-auth-source-p "chrome"))))

(ert-deftest ytm-radio-helper-headers-import-arguments ()
  "Build Rust helper arguments for request header import."
  (should
   (equal
    (ytm-radio--helper-import-headers-arguments
     "/tmp/request-headers.txt"
     "/tmp/ytm-auth.json")
    '("auth"
      "import-headers"
      "--input"
      "/tmp/request-headers.txt"
      "--output"
      "/tmp/ytm-auth.json"))))

(ert-deftest ytm-radio-helper-dia-import-arguments ()
  "Build Rust helper arguments for automatic Dia import."
  (let ((ytm-radio-helper-dia-cdp-port 29999)
        (ytm-radio-helper-dia-app "/Applications/Dia.app/Contents/MacOS/Dia"))
    (should
     (equal
      (ytm-radio--helper-import-dia-arguments "/tmp/ytm-auth.json")
      '("auth"
        "import-dia"
        "--output"
        "/tmp/ytm-auth.json"
        "--port"
        "29999"
        "--app"
        "/Applications/Dia.app/Contents/MacOS/Dia")))))

(ert-deftest ytm-radio-helper-dia-import-restart-arguments ()
  "Build Rust helper arguments for Dia import with restart."
  (let ((ytm-radio-helper-dia-cdp-port 29999)
        (ytm-radio-helper-dia-app "/Applications/Dia.app/Contents/MacOS/Dia"))
    (should
     (equal
      (ytm-radio--helper-import-dia-arguments "/tmp/ytm-auth.json" t)
      '("auth"
        "import-dia"
        "--output"
        "/tmp/ytm-auth.json"
        "--port"
        "29999"
        "--app"
        "/Applications/Dia.app/Contents/MacOS/Dia"
        "--restart")))))

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

(provide 'ytm-radio-test)

;;; ytm-radio-test.el ends here
