# metaclean

[![CI](https://img.shields.io/github/actions/workflow/status/26zl/metaclean/ci.yml?branch=main&label=CI)](https://github.com/26zl/metaclean/actions/workflows/ci.yml)
[![Gem](https://img.shields.io/gem/v/metaclean)](https://rubygems.org/gems/metaclean)
[![Ruby](https://img.shields.io/badge/ruby-%E2%89%A5%203.2-CC342D)](https://www.ruby-lang.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A small Ruby CLI that strips metadata from almost any file —
images, audio, video, PDFs, Office documents — and shows a colored before/after
diff of exactly what was removed.

It wraps four battle-tested tools and routes each file to the right one:

- **ExifTool** — the broadest format coverage (EXIF, IPTC, XMP, GPS, ID3, …)
- **mat2** — stricter on `.docx` / `.png` and Office/OpenDocument files (rebuilds the file)
- **qpdf** — rebuilds PDFs and clears residual metadata in unused streams
- **ffmpeg** — strips the Matroska containers (`.mkv` / `.webm`) the others can't write, by remuxing losslessly (stream copy, no re-encode)

## Why metaclean?

- **Verification-first:** it re-reads the cleaned file and refuses to write a
  result when known privacy metadata survives.
- **Safer defaults:** it writes `*_clean` copies by default; `--in-place` keeps a
  `.bak` and asks for confirmation unless `--force` is set.
- **Lossless routing:** it avoids mat2 paths that recompress JPEG/WebP or
  downconvert TIFF, and uses ffmpeg stream-copy for Matroska.
- **Batch-friendly:** failed or unverified files exit non-zero, so scripts and CI
  do not mistake uncertainty for success.

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
chmod +x bin/metaclean
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

# See what would change without writing anything
metaclean --dry-run photo.jpg
```

## Flags

| Flag | What it does |
| --- | --- |
| `--inspect` | Read-only — print metadata, never write |
| `--dry-run` | Simulate cleaning, show diff, write nothing |
| `-i`, `--in-place` | Overwrite originals (keeps a `<file>.bak`) |
| `-r`, `--recursive` | Recurse into directories |
| `-f`, `--force` | Skip the confirmation prompt |
| `-h`, `--help` | Show usage and exit |
| `-v`, `--version` | Show metaclean's version **and** the detected versions of exiftool/mat2/qpdf/ffmpeg (prints `not found` for any missing) |

## Publishing

The release workflow builds a `.gem` for every `v*` tag, attaches it to a
GitHub Release, and publishes it to RubyGems via a
[Trusted Publisher](https://guides.rubygems.org/trusted-publishing/) (OIDC) —
`rubygems/release-gem` with `id-token: write`. There is **no `RUBYGEMS_API_KEY`
secret**; the one-time prerequisite is registering this gem's Trusted Publisher
on rubygems.org.

```bash
git tag v2.0.0
git push origin v2.0.0
```

## Safety

- All shell-outs use argument arrays (`Open3.capture3(*args)`), so filenames
  with spaces, quotes, or shell metacharacters are safe.
- `--in-place` writes atomically: the file is built in a temp file and
  renamed into place, so a crash mid-run cannot leave a half-written original.
- Symlinks are always skipped — metaclean never cleans through a link.
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
- Naming no files (a missing path, or everything filtered out), failed files,
  and unverified cleans exit non-zero, so scripts do not mistake uncertainty for
  success.

## What it does *not* do

- Steganography (data hidden inside the pixel/audio data itself).
- Filesystem metadata (mtime, ownership) — that's the OS, not the file.
- Office macros or PDF JavaScript — open untrusted files in a sandbox.

The post-clean "still present" check is bounded by what ExifTool can re-read.
For container formats that mat2 cleans but ExifTool only partially parses (e.g.
`.zip`, `.epub` internals), metadata may be removed that the verification can't
independently confirm — a clean report means "the tools ran", not "every byte
was audited".

**SVG:** some mat2 builds (e.g. 0.14.0 on recent Python) crash on SVG, and
ExifTool is read-only for it — so on those systems metaclean cannot clean
`.svg`. It reports the file as **failed** (exit 1) and leaves the original
untouched rather than claiming a false "clean". Where mat2 handles SVG, it
cleans normally.

Keep ExifTool, mat2, qpdf, and ffmpeg updated; they parse hostile binary
formats and have had CVEs in the past.

## License

MIT
