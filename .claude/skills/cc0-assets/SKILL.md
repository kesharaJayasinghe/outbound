---
name: cc0-assets
description: Find, vet, process and add third-party CC0 assets (sounds, models, textures) to Outbound. Use when the user asks for new sound effects, ambience, characters, animations or other art that the project can't generate in code.
---

# Adding CC0 assets to Outbound

The project only ships **CC0 / public-domain** third-party assets, plus things it generates
itself. Prefer generating in code when the result is convincing (wind noise, vegetation and
leaf textures are all procedural). Download real recordings and models when synthesis would
sound or look fake.

## 1. Find and confirm the license

- OpenGameArt is the main source. Search, then fetch the asset page and confirm three things:
  the license is CC0, the author, and the exact file URL (`/sites/default/files/...`).
- Reject CC-BY, CC-BY-SA or unknown licenses unless the user explicitly accepts attribution
  terms. Note any "please credit" requests even on CC0 pages.
- Download into a fresh, empty scratch directory, not the project. Archives are untrusted:
  list them before extracting (`unzip -l`, `bsdtar -tf` for `.7z`), and extract only the
  files you need.

## 2. Inspect what you got (you can't listen or look directly)

- Duration and loudness: `ffprobe -show_entries format=duration`,
  `ffmpeg -i f -af volumedetect -f null -`
- Content: render spectrograms and waveforms, then read the image.
  - Birdsong and splashes show broadband or chirp energy.
  - Music shows steady horizontal harmonic lines; avoid it for ambience.
  - Drips show single tonal spikes.
  ```sh
  ffmpeg -i f -lavfi "showspectrumpic=s=1000x400:legend=1:scale=log" spec.png
  ffmpeg -i f -filter_complex "showwavespic=s=500x70:colors=white[w];color=c=0x202040:s=500x70[bg];[bg][w]overlay" -frames:v 1 wave.png
  ```
  This machine's ffmpeg can't render `drawtext` labels, so lay grids out in a known order.
- Models: instance the imported scene in a temporary script and print the node tree, bone
  names, animation names and lengths, rest-pose bone positions (for scale and facing), and
  whether clips have root motion.

## 3. Process audio

- **Encoder limits**: this ffmpeg has no `libvorbis`, and MP3 adds silent padding that
  breaks loops. Write 16-bit **WAV**; Godot compresses it to QOA on import.
- Footsteps and one-shots:
  - trim leading silence (`silenceremove=start_periods=1:start_threshold=-45dB`)
  - mono, with a fade-out if trimmed
  - normalise: `loudnorm=I=-16:TP=-1.5`, or around -14 for big impacts
- Ambience loops:
  - make them seamless by cross-fading the head into the tail:
    `[0]asplit[a][b];[a]atrim=0:X,asetpts=PTS-STARTPTS[head];[b]atrim=X:T,asetpts=PTS-STARTPTS[body];[body][head]acrossfade=d=X:c1=qsin:c2=qsin`
  - check the seam by plotting two copies back-to-back around the join
  - normalise beds to about -18 to -24 LUFS
  - use mono for 3D-positioned sources
  - lower the sample rate when the content allows it (22.05 kHz for wind or muffled sea)
- Output goes under `audio/` (one-shots in `audio/footsteps/` or a new subfolder).

## 4. Import settings

Run `Godot --headless --path . --import`, then edit the generated `.import` files and
re-import:

- Looping ambience: `edit/loop_mode=2`. QOA (`compress/mode=2`) is already the default.
- Palette or pixel textures: `detect_3d/compress_to=0`, and use nearest filtering in the
  material.

Commit the `.import` files: these settings live there.

## 5. Credit and wire up

- Add an entry to `audio/CREDITS.txt`, or a LICENSE/CREDITS file next to a model: title,
  author, URL, license, and what processing was done. Update the README credits line if
  there's a new author.
- Wire the asset into the game and verify with the `godot-verify` skill.
