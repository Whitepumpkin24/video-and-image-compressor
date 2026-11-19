# Video and Image Compressor

**Version 2.1.0**

A simple Windows app that compresses a **video or a photo** down to a **target file size**.
Pick a file, type a size (`20` MB for a video, `500` KB for a photo), click **Compress**, and get a smaller copy back.

- **Videos** are compressed with [FFmpeg](https://ffmpeg.org)
- **Images** are compressed with either [ImageMagick](https://imagemagick.org) or [CaesiumCLT](https://saerasoft.com/caesiumclt/), selectable in the app

Built with a PowerShell GUI. Handy for Discord, email, and messaging upload limits.

> **Vibe-coded project.** This was written with the help of AI. It works for me, but use it at your own risk. If in doubt, read the script: it is one plain-text file (`VideoImageCompressor.ps1`).

## Features

**Both**
- Compress to a target size instead of guessing quality settings
- Choose MB or KB for the target size
- Switches between Video and Image mode automatically when you pick a file
- Drag and drop, progress bar, cancel button, live log
- Safe by design: writes a temporary `.part` file and only renames it when finished, so your original and any existing files are never damaged by a failed or cancelled run
- Asks before overwriting an existing file
- Clear error messages, with details logged to a file

**Video (FFmpeg only)**
- Output: MP4, MKV, MOV (H.264 + AAC) or WebM (VP9 + Opus)
- **Auto GPU detection:** NVIDIA NVENC, Intel Quick Sync or AMD AMF if available, otherwise the CPU (x264)
- Automatic CPU fallback if a GPU encode fails, plus a **Force CPU** option
- Optional 720p downscale (never upscales smaller videos)
- Warnings for targets that are too small or very low quality

**Image (ImageMagick or CaesiumCLT)**
- Output: JPG, WebP or PNG
- Select either available engine in the **Image engine** dropdown; ImageMagick is the default when both are installed
- ImageMagick uses adaptive quality estimation and resolution search, optimized JPEG encoding, and lossless PNG filter optimization
- CaesiumCLT uses native target-size compression for JPG/WebP and lossless PNG optimization (level 6)
- Both verify the actual file size and reduce resolution if necessary, down to a minimum scale of 20%
- Optional maximum width/height in pixels
- Removes personal metadata (EXIF, GPS) by default; ImageMagick retains compatible ICC profiles, and CaesiumCLT retains JPEG ICC profiles by default
- ImageMagick accepts JPG/JPEG, PNG, WebP, BMP and TIFF; CaesiumCLT accepts JPG/JPEG, PNG and WebP in this app
- Both work on a private copy of the file

## Requirements

- Windows 10 (1809 or later) or 11, x64
- Windows PowerShell 5.1 (already built in)
- `ffmpeg.exe` and `ffprobe.exe` (bundled in the installer)
- ImageMagick portable build in an `imagemagick` folder (bundled in the installer)
- CaesiumCLT 1.5.0 or newer in a `caesium` folder (bundled in the installer)
- When running from source, either image engine is sufficient for Image mode; FFmpeg and FFprobe are still required at startup.

## Install

1. Go to the [Releases](../../releases) page.
2. Download `VideoImageCompressorSetup.exe`.
3. Run it, accept the agreement, and finish the wizard. You get a Start Menu entry and an optional desktop shortcut.

Windows SmartScreen may say "Windows protected your PC" because the installer is not code-signed. Click **More info**, then **Run anyway**.

This software uses FFmpeg (gyan.dev essentials build, licensed under the GPLv3). Its source can be downloaded [here](https://github.com/GyanD/codexffmpeg/releases).

## Usage

1. Open **Video and Image Compressor**.
2. Click **Browse** (or drag a file into the window). The mode switches to Video or Image for you.
3. If compressing an image, choose **ImageMagick** or **CaesiumCLT** in the **Image engine** dropdown. For videos, the GPU encoder is detected automatically.
4. Type the **Target size** (the box starts empty, or use the **-** / **+** buttons), choose **MB** or **KB**, and pick the **Format**.
5. Set any optional dimensions, metadata removal or video options, then click **Compress**.
6. When it finishes, the file is saved next to the original as `name_compressed.<format>` by default (for example `holiday_compressed.mp4` or `photo_compressed.jpg`).

## Run from source (no installer)

1. For video, put `ffmpeg.exe` and `ffprobe.exe` next to the script, or install FFmpeg with `winget install Gyan.FFmpeg`.
2. For ImageMagick, put the portable build in an `imagemagick` folder next to the script. It needs `magick.exe` plus the `.xml` files and `sRGB.icc` from the same download.
3. For CaesiumCLT, download the Windows x64 release (version 1.5.0 or newer) from [its official release page](https://github.com/Lymphatus/caesium-clt/releases). Extract `caesiumclt.exe`, `LICENSE.md` and `README.md` into a `caesium` folder next to the script.
4. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\VideoImageCompressor.ps1
```

Or double-click `VideoImageCompressor.bat`, which launches the GUI through a headless console host without leaving a blank terminal open. Image mode works when either image engine is detected; if both are missing, only Video mode is available.

## How it works

**Video**
1. `ffprobe` reads the video duration.
2. Total bitrate = target size x 8 x safety margin / duration. The margin is 5% for CPU and 8% for GPU, because GPU encoders land less exactly.
3. Audio gets 128 kbps (64 kbps for very small targets). The rest goes to video.
4. **CPU:** two-pass encode for accurate size. **GPU:** single-pass capped VBR for speed.
5. **WebM** always uses the CPU (VP9 + Opus) and is slower, because WebM cannot hold H.264.

**Image (ImageMagick)**
1. For JPG/WebP, ImageMagick tries quality 95 first. If it fits, the result is accepted.
2. If it is too large, the script tests quality 45 and uses adaptive interpolation with a binary-search fallback to find a suitable quality.
3. If even the quality floor does not fit, the script estimates the resolution from the square root of the target-to-current size ratio and refines the scale before refining quality again.
4. PNG uses lossless compression level 9 with adaptive and alternate RLE filtering before reducing resolution.
5. Optional metadata removal preserves compatible ICC color profiles; orientation and optional maximum dimensions are applied to each attempt.

**Image (CaesiumCLT)**
1. For JPG/WebP, the script passes the target in bytes using `--max-size`. CaesiumCLT manages the compression search internally.
2. For PNG, the script uses `--lossless --png-opt-level 6` instead of reducing color quality.
3. The script verifies the measured output size. If necessary, it estimates and refines the resolution with `--long-edge` and `--no-upscale`.
4. Metadata removal retains orientation where supported; JPEG ICC profiles are preserved by default.

Both image engines always encode from the original private copy and accept only a nonempty output at or below the target. If the target cannot be reached within the configured scale limits, the app reports an error. Video encoding estimates the target using bitrate and safety margins, and warns if the final video exceeds the target.

| Feature | ImageMagick | CaesiumCLT |
|---|---|---|
| Target-size search | Managed by PowerShell | Native `--max-size` for JPG/WebP |
| PNG optimization | Lossless level 9, alternative filters | Lossless level 6 |
| Resolution search | Adaptive, minimum 20% | Adaptive, minimum 20% |
| Input formats | JPG, PNG, WebP, BMP, TIFF | JPG, PNG, WebP |
| Output formats | JPG, PNG, WebP | JPG, PNG, WebP |
| Color management | Compatible ICC preservation and sRGB conversion | JPEG ICC preservation by default |

For everyday JPG/WebP target-size compression, try CaesiumCLT. For broader input compatibility or advanced color management, use ImageMagick. Actual speed and visual quality depend on the image and target size. For photos, JPG or WebP usually reaches smaller targets more readily than lossless PNG.

| Format | Type | Codecs | Notes |
|---|---|---|---|
| MP4 | Video | H.264 + AAC | Most compatible. Plays almost everywhere |
| MKV | Video | H.264 + AAC | Flexible container, great for PC players |
| MOV | Video | H.264 + AAC | Apple and video-editing software |
| WebM | Video | VP9 + Opus | Web use. CPU only, slower to encode |
| JPG | Image | JPEG | Best for photos. Works everywhere |
| WebP | Image | WebP | Smaller than JPG. Modern apps and web |
| PNG | Image | PNG | Lossless. Best for screenshots and graphics |

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing happens when launching | Errors are logged to `%LOCALAPPDATA%\VideoImageCompressor\error.log` |
| Image mode is greyed out | Neither `imagemagick\magick.exe` nor `caesium\caesiumclt.exe` was detected |
| CaesiumCLT is missing from the dropdown | Install version 1.5.0 or newer in the `caesium` folder, then restart the app |
| CaesiumCLT rejects a BMP or TIFF | Select ImageMagick; the CaesiumCLT path accepts JPG, PNG and WebP |
| Encoder shows `[fallback]` | The GPU encode failed (often an old driver), so it used the CPU. Update your GPU drivers |
| File is a bit smaller than the target | Expected. Image outputs must fit the limit; video uses a bitrate safety margin |
| "Enter a target size" appears | The size box starts empty on purpose. Type a number |
| "Target is too small" (video) | Increase the target size or use a shorter video |
| "Could not reach ..." (image) | The target is too small even at 20% size. Choose a larger target. For PNG, try JPG or WebP |
| WebM is slow or Force CPU is greyed out | WebM (VP9) always runs on the CPU. Use MP4 or MKV for GPU speed |
| SmartScreen warning | Installer is unsigned. More info > Run anyway |

## Build the installer

Uses [Inno Setup](https://jrsoftware.org/isinfo.php) (`winget install JRSoftware.InnoSetup`).

1. Put these files in one folder: `VideoImageCompressor.ps1`, `VideoImageCompressor.iss`, `VideoImageCompressor.ico`, `Agreement.txt`, `LICENSE` (this project's MIT license), `LICENSE-FFmpeg.txt` (the license text that comes with your FFmpeg download, renamed), `THIRD-PARTY-NOTICES.txt`, `ffmpeg.exe`, `ffprobe.exe`.
2. Add an `imagemagick` subfolder containing `magick.exe`, all the `.xml` files, `sRGB.icc`, `LICENSE.txt` and `NOTICE.txt` from the ImageMagick portable download (Q16 x64). The other `.exe` files in that download are not needed.
3. Add a `caesium` subfolder containing `caesiumclt.exe`, `LICENSE.md` and `README.md` from the official Windows x64 release (1.5.0 or newer).
4. Open `VideoImageCompressor.iss` in Inno Setup and press **F9**.
5. `VideoImageCompressorSetup.exe` is created in the same folder. The installer bundles both image engines and their included license files. The shortcuts use the headless console host to launch the GUI.

All third-party executables and compiled installers are excluded from source control (see `.gitignore`). Download the [FFmpeg essentials build](https://www.gyan.dev/ffmpeg/builds/), [portable ImageMagick](https://imagemagick.org/download/) and [CaesiumCLT Windows release](https://saerasoft.com/caesiumclt/). Keep the original upstream license and notice files with the corresponding binaries.

## Repo contents

| File | Purpose |
|---|---|
| `VideoImageCompressor.ps1` | The whole app (PowerShell + WinForms GUI) |
| `VideoImageCompressor.iss` | Inno Setup installer script |
| `VideoImageCompressor.bat` | Double-click launcher for running from source |
| `Agreement.txt` | Agreement shown during install |
| `LICENSE` | MIT license for this project's own code |
| `THIRD-PARTY-NOTICES.txt` | Licenses, versions and source links for FFmpeg, ImageMagick and CaesiumCLT |
| `imagemagick/` | ImageMagick portable build, configuration, color profile and upstream license/notice files |
| `caesium/` | CaesiumCLT executable and upstream license and README |
| `VideoImageCompressor.ico` | App icon |
| `README.md` | This file |
| `.gitignore` | Keeps third-party executables and built installers out of the repo |

## Disclaimer

Provided "as is" without warranty of any kind. The author is not responsible for lost or damaged files or any other problem. Keep a backup of your original files.

## Third-party software

This project runs three separate programs through their command lines. They are not part of this repo's code, and each keeps its own license. See `THIRD-PARTY-NOTICES.txt` for versions and source links.

- [FFmpeg](https://ffmpeg.org) (video). The installer bundles the unmodified gyan.dev "essentials" build, which is licensed under the **GPLv3**. Its license text is installed as `LICENSE-FFmpeg.txt`. The source for the bundled build is available from [gyan.dev](https://www.gyan.dev/ffmpeg/builds/), the build's [GitHub releases](https://github.com/GyanD/codexffmpeg/releases) (each release page links the exact FFmpeg source commit) and [ffmpeg.org](https://ffmpeg.org/download.html).
- [ImageMagick](https://imagemagick.org) (images). Copyright (C) 1999 ImageMagick Studio LLC. The installer bundles the unmodified portable build, licensed under the [ImageMagick License](https://imagemagick.org/license/) (very similar to Apache 2.0). Its license and a list of its own third-party components are installed as `imagemagick\LICENSE.txt` and `imagemagick\NOTICE.txt`. Source code: [github.com/ImageMagick/ImageMagick](https://github.com/ImageMagick/ImageMagick).
- [CaesiumCLT](https://saerasoft.com/caesiumclt/) (images). The installer bundles the unmodified Windows x64 release (currently 1.5.0), licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). Its upstream license and README are installed as `caesium\LICENSE.md` and `caesium\README.md`. Source code and release information: [github.com/Lymphatus/caesium-clt](https://github.com/Lymphatus/caesium-clt). Bundled dependencies retain their applicable licenses.

This project is not affiliated with or endorsed by the FFmpeg project, gyan.dev, ImageMagick Studio LLC or SaeraSoft/CaesiumCLT. FFmpeg is a trademark of Fabrice Bellard.

## License

The script, installer script and project documentation in this repo are released under the **MIT License** (see `LICENSE`). The bundled FFmpeg, ImageMagick and CaesiumCLT programs and their upstream documentation retain their respective licenses, as described above.

## Author

Whitepumpkin
