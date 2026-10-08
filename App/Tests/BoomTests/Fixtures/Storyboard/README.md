# Public storyboard controls

These are synthetic local fixtures, with no private recording or download.
`speech.wav` was generated with macOS Samantha saying:

> The clock struck seven. Mara opened the blue door.

`scene-speech.mp4` is eight seconds at 24 fps: red until 2.750s, blue until
5.500s, then green. Speech follows one second of silence; the soundtrack spans
the entire eight seconds. `offset-audio.mp4` has a genuinely delayed audio track
(its first nonempty AVFoundation edit segment starts near one second), followed
by silence. `static-long.mp4` is 70 seconds of red at 4 fps, testing the one-minute
model view and explicit omission. `static-sparse.mp4` is nine seconds at 1 fps,
testing repeated decode results and low-frame-rate coverage.

The decoder tests require actual shot pixels, exact continuous waveform
reassembly, bounded visual gaps, source hashes, cancellation, encrypted original
retention, and matching document/chat preparation. Rust tests separately exercise
flashes, steady change, dense cuts, invalid timelines, and chronological prompt
compilation. Model controls retain full, frames-only, and sound-only outputs;
nonempty generation is not a semantic pass.

Generation used `/usr/bin/say` and developer-installed FFmpeg (`libx264`/AAC).
Neither executable is an app runtime dependency. The commands are in
`scripts/generate-storyboard-fixtures.sh`; generation requires a fresh output
directory and deliberately does not overwrite checked-in fixtures.
