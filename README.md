# RaceSync Calculator

This Mac app helps to quickly calculate the delay needed to sync a live session of MultiViewer's live timing with a live TV race broadcast, using either the visible session timer or the race session duration set by the FIA.

[image]

## Session timer
For broadcasts with a session timer, such as FP or qualifying:

1. Enter a value in **Session time** that hasn't been reached yet, e.g., `34:20`.
2. Capture the **MultiViewer timer** and enter the current MultiViewer delay in ms.
3. When the TV session time matches the entered value, click **Calculate delay**.
4. Copy the recommended delay into MultiViewer.

[image]

## Race timer
For sessions without a visible timer, like a race:

1. Set a **2-hour timer** in the Clock app.
2. Capture the **MultiViewer** and **Clock app timer**.
3. Enter the current MultiViewer delay in ms.
4. Start the clock timer when the lights go out.
5. When both timers are running, click **Calculate delay**.
6. Copy the recommended delay into MultiViewer.

[image]

## Install

Requires macOS 15.2 or later. Download the app from [Releases](https://github.com/TimMacy/RaceSync-Calculator/releases), or build from source with `bash build.sh`.

If macOS blocks the app, choose [Open Anyway](https://support.apple.com/102445) under **System Settings → Privacy & Security**. Allow screen recording when prompted.