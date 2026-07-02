# metaclean

```
███╗   ███╗███████╗████████╗ █████╗  ██████╗██╗     ███████╗ █████╗ ███╗   ██╗
████╗ ████║██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║     ██╔════╝██╔══██╗████╗  ██║
██╔████╔██║█████╗     ██║   ███████║██║     ██║     █████╗  ███████║██╔██╗ ██║
██║╚██╔╝██║██╔══╝     ██║   ██╔══██║██║     ██║     ██╔══╝  ██╔══██║██║╚██╗██║
██║ ╚═╝ ██║███████╗   ██║   ██║  ██║╚██████╗███████╗███████╗██║  ██║██║ ╚████║
╚═╝     ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝
  strip EXIF · IPTC · XMP · GPS · ID3 — leave the file clean
```

[![CI](https://img.shields.io/github/actions/workflow/status/26zl/metaclean/ci.yml?branch=main&label=CI)](https://github.com/26zl/metaclean/actions/workflows/ci.yml)
[![Gem](https://img.shields.io/gem/v/metaclean)](https://rubygems.org/gems/metaclean)
[![Ruby](https://img.shields.io/badge/ruby-%E2%89%A5%203.2-CC342D)](https://www.ruby-lang.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A small Ruby CLI that strips metadata from almost any file —
images, audio, video, PDFs, Office documents — and shows a colored before/after
diff of exactly what was removed.

It wraps four external tools and routes each file to the right one:

- **ExifTool** — the broadest format coverage (EXIF, IPTC, XMP, GPS, ID3, …)
- **mat2** — stricter on `.docx` / `.png` and Office/OpenDocument files (rebuilds the file)
- **qpdf** — rebuilds PDFs and clears residual metadata in unused streams
- **ffmpeg** — strips the Matroska containers (`.mkv` / `.webm`) the others can't write, by remuxing losslessly (stream copy, no re-encode)

## Why metaclean?

- **Verification-first:** it re-reads the cleaned file and only commits a
  result whose final status is `cleaned`; failed, unsupported and unverified
  candidates are deleted.
- **Safer defaults:** it writes `*_clean` copies by default; `--in-place` keeps a
  `.bak` and asks for confirmation unless `--force` is set. Note the `.bak` is the
  **original, with all its metadata** — delete or move the `.bak` files before
  sharing an in-place-cleaned folder.
- **Content-preserving routing:** it keeps image orientation, avoids lossy
  raster paths, and preserves Matroska chapters and languages.
- **Nested-content guard:** PDFs and Matroska files with attachments or cover
  art fail closed until their embedded payloads can be independently cleaned.
- **Batch-friendly:** failed, unsupported or unverified files exit non-zero, so
  scripts and CI do not mistake uncertainty for success.

## What it looks like

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📄 photo.jpg
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
▸ Before (5 embedded tags)
  [GPS]
    GPSLatitude        59.9139
    GPSLongitude       10.7522
  [IFD0]
    Artist             Jane Doe
    Make               Apple
    Model              iPhone 15
  Pipeline: exiftool
    ✓ exiftool
▸ After (0 embedded tags)
  (no embedded metadata)
▸ Diff
▸ Removed (5)
  - GPS:GPSLatitude    59.9139
  - GPS:GPSLongitude   10.7522
  - IFD0:Artist        Jane Doe
  - IFD0:Make          Apple
  - IFD0:Model         iPhone 15
✓ → photo_clean.jpg
```

## Install

```bash
# 1. Install the four required tools — metaclean refuses to run without all of them
brew install exiftool mat2 qpdf ffmpeg                    # macOS
sudo apt install libimage-exiftool-perl mat2 qpdf ffmpeg  # Debian / Ubuntu
sudo dnf install perl-Image-ExifTool mat2 qpdf ffmpeg     # Fedora
sudo pacman -S perl-image-exiftool mat2 qpdf ffmpeg       # Arch
# Windows: use WSL2 (see below), then the Debian / Ubuntu line above

# 2. Install metaclean from RubyGems
gem install metaclean
metaclean --version
metaclean --help
```

From a source checkout:

```bash
git clone https://github.com/26zl/metaclean.git && cd metaclean
bundle install
bundle exec rake install
metaclean --version
```

You can also run the checkout without installing it by using
`./bin/metaclean`.

### Windows

Native Windows isn't supported: `mat2` depends on Python + GTK and doesn't
install cleanly there, and metaclean requires all four tools. Use
**[WSL2](https://learn.microsoft.com/windows/wsl/install)** with Ubuntu and
follow the Debian / Ubuntu line above — everything runs inside WSL.

### Android

There's no native Android app, but the full CLI runs unchanged inside
**[Termux](https://f-droid.org/packages/com.termux/)** (install it from F-Droid,
not the Play Store) via a Debian proot — where `mat2` and the other three tools
install cleanly from `apt`:

```bash
pkg install proot-distro
termux-setup-storage                 # tap "Allow" to grant access to your files
proot-distro install debian
proot-distro login debian --bind ~/storage/shared:/sdcard
# now inside Debian:
apt update && apt install -y ruby mat2 libimage-exiftool-perl qpdf ffmpeg
gem install metaclean
metaclean /sdcard/DCIM/Camera/photo.jpg
```

The `--bind` is what lets metaclean reach your photos — without it Debian can't
see the phone's storage.

## Quick start

These examples assume metaclean is installed as a gem. From a source checkout,
replace `metaclean` with `./bin/metaclean`.

```bash
# Show metadata, do not modify
metaclean --inspect photo.jpg

# Clean a file → writes photo_clean.jpg next to the original
metaclean photo.jpg

# Overwrite the original (a .bak is kept by default)
metaclean --in-place photo.jpg

# Clean a whole folder, recursively, no prompts
metaclean -r --in-place --force ./vacation

# See what would change; a private temporary copy is removed afterwards
metaclean --dry-run photo.jpg

# Avoid writing private metadata values to a log
metaclean --redact-values photo.jpg
```

## Flags

| Flag | What it does |
| --- | --- |
| `--inspect` | Read-only — print metadata, never write |
| `--dry-run` | Simulate on a private mode-0700 temporary copy; keep no output |
| `-i`, `--in-place` | Overwrite originals (keeps a `<file>.bak` — the **original, metadata intact**; remove it before sharing) |
| `-r`, `--recursive` | Recurse into directories |
| `-f`, `--force` | Skip the confirmation prompt |
| `-q`, `--quiet` | Suppress normal output; warnings and errors remain |
| `--redact-values` | Hide metadata values in tables and diffs |
| `--show-values` | Show values even when stdout is redirected |
| `--allow-icc-metadata` | Keep a non-standard ICC profile's identifying text; recognized standard color spaces (sRGB, Display P3, …) clean without it |
| `-h`, `--help` | Show usage and exit |
| `-v`, `--version` | Show metaclean's version **and** the detected versions of exiftool/mat2/qpdf/ffmpeg (prints `not found` for any missing) |

Exit codes are `0` for a fully successful batch, `1` for failed, unsupported,
unverified or incomplete work, `2` for a missing toolchain, and `130` for
Ctrl-C.

## Supported formats

Routing covers the formats supported by the installed toolchain, including:

- images: JPEG, PNG, GIF, BMP, TIFF, WebP, HEIC, PPM, SVG and DNG;
- audio/video: MP3, FLAC, Ogg/Opus, WAV, AIFF, MP4/M4A/MOV, AVI, WMV and Matroska;
- documents: PDF, OOXML, OpenDocument, EPUB, HTML/XHTML and CSS;
- archives/data: ZIP, TAR and BitTorrent files.

Support still depends on the installed ExifTool/mat2/qpdf/ffmpeg versions.
Unknown or unsupported formats are never treated as success. PDFs and Matroska
files containing attachments or cover-art streams are reported unverified or
failed and are not written.

ICC profiles are retained because removing them can change color rendering.
Recognized standard color spaces (sRGB, Display P3, Adobe RGB, the generic
profiles, …) are shared by countless files and are not identifying, so they
clean normally. A profile whose description is not a known standard can carry a
person's or organization's name in its description, creator, manufacturer or
copyright fields, so it blocks commit by default — review it and pass
`--allow-icc-metadata` to keep it.

## Publishing

The release workflow accepts a matching `v*` tag only when its commit belongs
to `main`. It tests every supported Ruby version, builds a `.gem`, attaches it
to a GitHub Release, and publishes it to RubyGems via a
[Trusted Publisher](https://guides.rubygems.org/trusted-publishing/) (OIDC) —
`rubygems/release-gem` with `id-token: write`. There is **no `RUBYGEMS_API_KEY`
secret**; the one-time prerequisite is registering this gem's Trusted Publisher
on rubygems.org.

Replace `X.Y.Z` with the version in `lib/metaclean/version.rb` — the release
workflow refuses to publish if the tag and that version disagree.

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

## Safety

- All shell-outs use argument arrays (no shell is involved), so filenames with
  spaces, quotes, or shell metacharacters are safe.
- Each external tool, including version probes, runs under a wall-clock timeout
  and output cap. Cleaning defaults to 120 s; probes use a shorter limit. For
  very large media on slow or network storage, raise the timeout with
  `METACLEAN_TIMEOUT=<seconds>` (e.g. `METACLEAN_TIMEOUT=600`).
- Tool output is created inside a private mode-0700 workspace and is rejected
  if it is a symlink or non-regular file. Normal commits stage on the destination
  filesystem for atomic rename; dry-run uses the system temp area. metaclean
  fails instead of proceeding when private permissions cannot be enforced.
- `--in-place` builds the clean file privately, verifies that the source has not
  changed, preserves ownership/permissions/ACLs/extended attributes with the
  host's native `cp`, creates the metadata-bearing `.bak`, and then renames into
  place. Failure to preserve these attributes or create a hard-link backup
  aborts the commit; use the default `*_clean` mode on filesystems without hard
  links.
- Final symlinks and user-controlled symlinks in parent path components are
  rejected. Parent-directory identities are checked again before commit.
- Folder and recursive (`-r`) scans deliberately skip hidden files and hidden
  directories, plus metaclean's outputs (`*_clean`, `*_clean.*`, `*.bak`).
  Name a hidden file explicitly if it should be cleaned.
- A `<file>.bak` left by `--in-place` is the **untouched original** and still
  contains all its metadata. Its actual collision-safe path is reported even
  with `--force`, but it is yours to delete or move before sharing the folder.
- Filename collisions (`photo_clean.jpg` already exists, `.bak` already
  exists) are resolved with `_1`, `_2`, … suffixes, including late collisions
  that appear while a file is being cleaned.
- After cleaning, metaclean re-reads the file and warns if known
  privacy-relevant tags (GPS, MakerNotes, Author, camera serial number, etc.)
  survived.
- A file whose strip leaves a privacy residual is **never written** — no
  `_clean` copy and no `--in-place` overwrite — it is reported failed and the
  original is left untouched.
- metaclean requires ExifTool, mat2, qpdf, and ffmpeg, and refuses to run (with
  install instructions, exit code 2) if any is missing — so the post-clean
  residual check always runs.
- Naming no files, discovery errors, unsupported formats, failed files and
  unverified candidates all exit non-zero.
- When stdout is redirected, metadata values are redacted by default. Use
  `--show-values` only when the destination log is trusted.
- External tool versions are recorded in CI and shown by `metaclean --version`.
  Keep OS packages updated; release tests exercise the supported Ruby range and
  capability-check qpdf/ffmpeg output rather than trusting version strings.

## What it does *not* do

- Steganography (data hidden inside the pixel/audio data itself).
- Renaming files or directories, or removing filesystem timestamps. In-place
  mode preserves filesystem security metadata; a new `*_clean` copy naturally
  has a new inode.
- Office macros or PDF JavaScript — open untrusted files in a sandbox.

The post-clean "still present" check is bounded by what ExifTool can re-read.
For container formats that mat2 cleans but ExifTool only partially parses (e.g.
`.zip`, `.epub` internals), metadata may be removed that the verification can't
independently confirm — a clean report means "the tools ran", not "every byte
was audited".

Nested files are a separate trust boundary. PDF attachments and Matroska
attachments/cover art currently fail closed instead of being preserved under a
false clean result. Archive/document formats are accepted only when their
cleaning tool completes; do not treat metaclean as a malware scanner.

**SVG:** some mat2 builds (e.g. 0.14.0 on recent Python) crash on SVG, and
ExifTool is read-only for it — so on those systems metaclean cannot clean
`.svg`. It reports the file as **failed** (exit 1) and leaves the original
untouched rather than claiming a false "clean". Where mat2 handles SVG, it
cleans normally.

Keep ExifTool, mat2, qpdf, and ffmpeg updated; they parse hostile binary
formats and have had CVEs in the past.

## License

MIT
