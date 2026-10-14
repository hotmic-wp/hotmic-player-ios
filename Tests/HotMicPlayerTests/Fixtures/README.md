# Native test media

These four tiny MP4s are SDK-owned synthetic gray video generated entirely from
FFmpeg's `color` filter; no private, partner, benchmark or third-party footage is
used. They contain H.264 video at 160x90, 10 fps, no audio, and durations 1, 3 and
20 seconds. `portrait-1.mp4` remuxes the 1-second video with a 90-degree display
matrix (90x160 displayed). They are test resources only.

`generate.sh` records the generation commands and refuses to overwrite files.
The committed assets were generated with FFmpeg 8.1.2 / libx264, on macOS ARM64.
`SHA256SUMS` binds their bytes; encoder-version changes may change those hashes.
Generate in an empty directory when intentionally updating them, inspect native
properties, and update the checksum list. No generation runs during unit tests.

Every `videoFixture` call copies a bundle resource to a unique caller-owned
URL; existing test defers delete it. Native review cases verify codec, duration,
rotation, decoded frames and copy isolation. Existing SDK cases still validate
native assignments, playback readiness, seek/reset and UI continuity.

The former AVAssetWriter readiness/finish/cancellation helper is removed. Its
embedded self-checks exercised only that test encoder, so they are replaced by
resource validation in the same existing case; no SDK-facing case is removed.
