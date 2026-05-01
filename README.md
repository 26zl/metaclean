# metaclean

A small cross-platform Ruby CLI that strips metadata from almost any file
(images, audio, video, PDFs, Office documents, …) and shows you a colored
before/after diff of exactly what was removed.

It wraps three battle-tested tools and routes each file to the right one:

- **ExifTool** — the broadest format coverage (EXIF, IPTC, XMP, GPS, ID3, …)
- **mat2** — stricter on `.docx` / `.pdf` / `.png` (rebuilds the file)
- **qpdf** — rebuilds PDFs and clears residual metadata in unused streams

## Install

```bash
# 1. Install the underlying tools (ExifTool is required, mat2 + qpdf optional)
brew install exiftool mat2 qpdf                    # macOS
sudo apt install libimage-exiftool-perl mat2 qpdf  # Debian / Ubuntu
sudo dnf install perl-Image-ExifTool mat2 qpdf     # Fedora
sudo pacman -S perl-image-exiftool mat2 qpdf       # Arch
scoop install exiftool qpdf                        # Windows

# 2. Install metaclean after it has been published to RubyGems
gem install metaclean
metaclean --version
metaclean --help
```

From a source checkout before publishing:

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

You also need Ruby itself. The recommended installer is
[**RubyInstaller**](https://rubyinstaller.org/) — it ships Ruby plus the
MSYS2 toolchain (DevKit) that some gems need to compile native extensions.
`scoop install ruby` and `choco install ruby` install the same RubyInstaller
distribution under the hood.

Note: `mat2` is hard to install on native Windows (it depends on Python +
GTK). If you want full coverage, the simplest route is
**[WSL2](https://learn.microsoft.com/windows/wsl/install)** with Ubuntu, then
follow the Debian/Ubuntu line above. On native Windows without `mat2`,
metaclean still works — ExifTool + qpdf cover the common cases.

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

# Clean a whole folder, recursively, no prompts, no backups
metaclean -r --in-place --no-backup --force ./vacation

# See what would change without writing anything
metaclean --dry-run photo.jpg
```

## Flags

| Flag | What it does |
|---|---|
| `--inspect` | Read-only — print metadata, never write |
| `--json` | JSON output (with `--inspect`) |
| `--dry-run` | Simulate cleaning, show diff, write nothing |
| `-i`, `--in-place` | Overwrite originals |
| `--no-backup` | Do not keep `<file>.bak` (with `--in-place`) |
| `-r`, `--recursive` | Recurse into directories |
| `--types=jpg,png,…` | Only process these extensions |
| `--follow-symlinks` | Follow symlinks (default: skip) |
| `--keep-orientation` | Preserve EXIF Orientation |
| `--keep-color-profile` | Preserve embedded ICC profile |
| `--exiftool-only` | Use only ExifTool |
| `--no-mat2` / `--no-qpdf` / `--no-exiftool` | Disable a specific tool |
| `-f`, `--force` | Skip the confirmation prompt |
| `--strict-verify` | Exit non-zero if privacy tags survive |

## Publishing

The release workflow builds a `.gem` file for every `v*` tag. If the GitHub
repository has a `RUBYGEMS_API_KEY` secret, the workflow also publishes the gem
to RubyGems.

```bash
git tag v1.0.1
git push origin v1.0.1
```

## Safety

- All shell-outs use argument arrays (`Open3.capture3(*args)`), so filenames
  with spaces, quotes, or shell metacharacters are safe.
- `--in-place` writes atomically: the file is built in a temp file and
  renamed into place, so a crash mid-run cannot leave a half-written original.
- Symlinks are skipped by default.
- Filename collisions (`photo_clean.jpg` already exists, `.bak` already
  exists) are resolved with `_1`, `_2`, … suffixes.
- After cleaning, metaclean re-reads the file and warns if known
  privacy-relevant tags (GPS, MakerNotes, Author, camera serial number, etc.)
  survived. With `--strict-verify` this becomes a non-zero exit code.

## What it does *not* do

- Steganography (data hidden inside the pixel/audio data itself).
- Filesystem metadata (mtime, ownership) — that's the OS, not the file.
- Office macros or PDF JavaScript — open untrusted files in a sandbox.

Keep ExifTool, mat2, and qpdf updated; they parse hostile binary formats and
have had CVEs in the past.

## License

MIT
