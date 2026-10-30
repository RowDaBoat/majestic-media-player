* Create a media player app with a GUI that uses MPV.

* The GUI must have dark theme as its 'first citizen' feature. 

* Will have a navigation bar with: File, View, Play, Navigate, Help
    * File: 
        1. Open File (Ctrl+O)
        2. Open Recent
        3. Open Directory
        4. Close (Ctrl+X)
        5. (separator)
        6. Save screenshot (Alt+I)
        7. (separator)
        8. Load track from file
            * Subtitle file (Ctrl+Shift+O)
            * Audio file
        9. (separator)
        10. Properties
        11. (separator)
        12. Exit (Alt+X)
    * View
        * Compact mode (hides the window frames and navigation bar) (Ctrl+1)
        * Seek Bar (Ctrl+2)
        * Controls (Ctrl+3)
        * Status (Ctrl+4)
        * Playlist (Ctrl+5)
        * Run Log (Ctrl+6)
        * (separator)
        * Show OSD
        * Full Screen
        * Pan, Rotate & Zoom
            * Center (Numpad 5)
            * Move up (10 pixels default) (Numpad 8)
            * Move down (Numpad 2)
            * Move left (Numpad 4)
            * Move right (Numpad 6)
            * (separator)
            * 0 degrees (Alt+Numpad 5)
            * Rotate Clockwise (5 degrees default) (Alt+Numpad 6)
            * Rotate Counter-clockwise (Alt+Numpad 4)
            * (separator)
            * Restore size (Ctrl+Numpad 5)
            * Increase Size (5% default)  (Ctrl+Numpad 9)
            * Decrease Size (5% default) (Ctrl+Numpad 3)
            * Increase Width (Ctrl+Numpad 6)
            * Decrease Width (Ctrl+Numpad 4)
            * Increase Height  (Ctrl+Numpad 8)
            * Decrease Height (Ctrl+Numpad 2)
            * (separator)
            * Reset
        * Video Frame
            * Half size (radio)
            * Full size (radio)
            * Double size (radio)
            * Stretch to window (radio)
            * Fit (radio, default)
            * Aspect ratio
                * Original (default)
                * 4:3
                * 5:4
                * 16:9
                * 16:10
            * Preserve aspect ratio (toggle, default)
        * (separator)
        * On Top
            * Default
            * Always
            * While playing
            * While playing video
        * Options (O)
    * Play
        * Play/Pause (Space)
        * Stop (Space)
        * Frame forward (.)
        * Frame back (,)
        * Increase Rate (default x0.25) (Shift+.)
        * Decrease Rate (default -x0.25) (Shift+,)
        * Repeat
            * Forever (toggle)
            * (separator)
            * File (option)
            * Playlist (option, default)
        * (separator)
        * Audio Track
            * None
            * (list audio tracks from opened file here)
        * Subtitle Track
            * None
            * (list sub tracks from opened file here)
        * Video Track
            * None
            * (list video tracks from opened file here)
        * (separator)
        * Volume
            * Up (Up Arrow)
            * Down (Down Arrow)
            * Mute (Ctrl+M)
            * Max
        * After playback
            * Do nothing (radio, default)
            * Play next file in the folder (radio)
            * Turn off the monitor (radio)
            * Exit (radio)
            * Sleep (radio)
            * Hibernate (radio)
            * Shutdown (radio)
            * Log Off (radio)
            * Lock (radio)

* The title of the window follows the pattern: `filename`.`extension` - Majestic Media Player

* The layout inside the main GUI will be composed of:
    1. Navigation bar
    2. Video frame (if a file opened contains a video track)
        * Playlist (hidden by default. shares same )
    3. Seek bar
    4. Controls
        * Play
        * Pause
        * Stop
        * (separator)
        * Previous (open previous file in folder if sole item in playlist)
        * Decrease rate
        * Increase rate
        * Next (open next file in folder if sole item in playlist)
    5. Status 
        * Left side:
            * (icon of file open)
            * ("Playing", "Paused" or "Stopped")
        * Right side:
            * Current time / Duration time (HH:MM:SS)
            * Symbol displaying whether the opened file is stereo (two speakers in opposite directions), mono (a speaker pointihgt to the right), or no sound (a speaker with a cross near it).

* Clicking the video frame without moving the cursor plays the video
* Holding the mouse button on the video frame and moving the cursor moves the window instead.

* Window must be resizable and should have no problem resizing the video frame. If "Preserve aspect ratio" the window will change resolution in favor of the video file's aspect ratio.

* The seek bar should be able to be drawn things on top of the bar (eg. colored vertical lines) and support snapping. For example snapping to chapters.

* The seek bar would allow to jump to a certain part of the video.

* Hovering the seek bar should show a preview of the video before jumping onto whever the mouse cursor's position is.

* Pressing A and S switches to the next audio track and the next subtitle track respectively. Shift+A and Shift+S switches to the previous of each respectively.

* Volume soft cap is 100. Hard cap volume is 200.
* Mouse wheel changes volume in steps of 5. If turning up and going above soft cap, increment with steps of 2.
* If turning down volume, regardless of current amount, use steps of 5.

* Alt+Enter toggles full screen.

* Fullscreen should make the Seek bar, Controls and Status  (let's call it the "bottom layout") something that appears at the bottom of the screen for as long as the cursor is near the bottom side. The bottom layout in fullscreen mustn't move the video frame's position/dimensions when making it appear and disappear in the process.

* The cursor must disappear when playing a video and the cursor is not moving and placed on top of the video frame after 1 second (and it must appear again when mouse is moved again or the video is paused/stopped)

* Do all the scratchpad work here in `tmp/` (not in `/tmp/`).