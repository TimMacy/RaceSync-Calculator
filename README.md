# RaceSync Calculator <a href="https://github.com/TimMacy/RaceSync-Calculator/releases"><img height="25px" align="right" src="https://img.shields.io/github/v/release/TimMacy/RaceSync-Calculator?style=for-the-badge" alt="Releases"></a><a href="https://github.com/TimMacy/RaceSync-Calculator/blob/main/LICENSE"><img height="25px" align="right" src="https://img.shields.io/github/license/TimMacy/RaceSync-Calculator?style=for-the-badge&color=white" alt="MIT License"></a>

This Mac app helps to quickly calculate the delay needed to sync a live session of MultiViewer's live timing with a live TV race broadcast, using either the visible session timer or the race session duration set by the FIA.

[image][image]

## Session timer
For broadcasts with a session timer, such as Free Practice or Qualifying:

1. Click **Select MultiViewer timer region** and capture the time in the top-left corner of the NAME window.
2. Copy the MultiViewer delay into the **Current MultiViewer delay** field.
3. Enter a **Target time** that the TV broadcast hasn't reached yet.
4. Once the broadcast timer matches the target time, either click **Calculate delay** or hit return.
5. Copy the recommended delay into MultiViewer via the **copy button**.

[image]

## Race timer
For sessions without a visible timer, like a race:

1. Switch to the **Race timer**.
2. For a Sprint, click **Race mode** in the bottom-right corner to switch to **Sprint mode**. This has to be set before lights out!
3. Click **Select MultiViewer timer region** and capture the time in the top-left corner of the NAME window.
4. Copy the MultiViewer delay into the **Current MultiViewer delay** field.
5. Click and hold the **Lights out** button and release it the moment the five red lights go out on TV. Do not move the cursor off the button until released!
6. When the MultiViewer timer is running, click **Calculate delay** or hit return.
7. Copy the recommended delay into MultiViewer via the **copy button**.

Instead of the in-app timer, a 2-hour timer (1 hour for a Sprint) in the Clock app can also be captured via the **Capture Clock app region** button. The timer has to be started in the same way as mentioned in point 5.

[image]

## Install

Requires macOS 15.2 or later. Download the app from [Releases](https://github.com/TimMacy/RaceSync-Calculator/releases), or build from source with `bash build.sh`.

If macOS blocks the app, choose [Open Anyway](https://support.apple.com/102445) under **System Settings → Privacy & Security**. Allow screen recording when prompted.

## License

RaceSync Calculator is released under the [MIT License](LICENSE). The bundled fonts, [Saira Condensed](https://github.com/Omnibus-Type/Saira) and [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono), are licensed under the [SIL Open Font License 1.1](Fonts/); their license files are included in `Fonts/`.