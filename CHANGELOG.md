# Changelog

All notable changes to metaclean are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every version is also published as a
[GitHub Release](https://github.com/26zl/metaclean/releases) with the built gem
attached, and pushed to [RubyGems](https://rubygems.org/gems/metaclean). The
entries up to 4.3.1 were reconstructed from the commits between the release
tags; the compare links at the bottom show the complete diffs.

## [Unreleased]

### Fixed

- File names beginning with `~` (for example Office lock files such as
  `~$report.docx`) no longer abort the run with `ArgumentError`; paths are made
  absolute without tilde expansion, so the path guard checks the literal file
  instead of a home directory.
- Non-ASCII file names no longer crash with `Encoding::CompatibilityError` under
  a C/POSIX locale (cron jobs, containers, minimal shells); command-line
  arguments and directory entries are handled as UTF-8 byte strings.
- A non-ASCII byte in an external tool's error message (typically the file path
  quoted by exiftool or mat2) no longer aborts the whole batch with a Ruby
  backtrace; tool output is normalised to valid UTF-8 before it is matched or
  displayed.
- The confirmation prompt is written to stderr, so it stays visible when stdout
  is redirected to a file.
- A PNG colour profile (`iCCP`) is retained and gated like in other formats:
  its profile name is treated as part of the profile, so a standard colour
  space cleans normally and a custom profile needs `--allow-icc-metadata`.

### Changed

- PNG files are cleaned by ExifTool alone instead of mat2 followed by ExifTool.
  mat2 rebuilt the image through cairo, which turned palette and 16-bit
  greyscale PNGs into RGB(A) and dropped the `gAMA` chunk and the embedded
  colour profile. The new route removes every `tEXt`, `zTXt` and `iTXt` chunk
  (including XMP), `eXIf` and `tIME`, also after the image data, and keeps the
  pixel data, palette, bit depth, colour type and the `gAMA`, `cHRM`, `sRGB`,
  `sBIT`, `bKGD` and `pHYs` chunks byte for byte. ExifTool's `-all=` would
  also delete `gAMA`, `sRGB` and `pHYs`, so they are copied back explicitly.
- `Metaclean.safe_path` also anchors relative names beginning with `@`, which
  qpdf would otherwise read as an argument file.
- The gem's `changelog_uri` points at this file, which is now shipped in the gem.

### Added

- `.editorconfig` matching the repository's two-space, LF style, and this
  changelog.

## [4.3.1] - 2026-07-24

### Added

- Dependabot updates for GitHub Actions, and an issue-template link to private
  vulnerability reporting.

### Changed

- The missing-tool message names `ffmpeg (with ffprobe)`, since both binaries
  are required.
- `rake` is pinned to `~> 13.0`; SECURITY.md documents that ICC gating trusts
  the profile's own `ProfileDescription`.

### Fixed

- The CLI no longer configures display output twice (the runner already does).

## [4.3.0] - 2026-07-03

### Changed

- Warnings, the list of surviving privacy tags and the failure count are
  written to stderr instead of stdout, so privacy notes stay visible when
  output is piped or logged.
- `NO_COLOR` takes precedence over `FORCE_COLOR`.

### Added

- A hint to pass `--allow-icc-metadata` when only ICC profile text remains, and
  descriptions for `-h` and `-v` in `--help`.

## [4.2.0] - 2026-07-02

### Added

- `-q`/`--quiet`, `--redact-values`, `--show-values` (values are redacted when
  stdout is redirected) and `--allow-icc-metadata`.
- `METACLEAN_TIMEOUT` to raise the per-tool wall-clock limit.
- A nested-content guard: PDFs with attachments and Matroska files with
  attachments or cover art fail closed instead of being reported clean.
- A coverage floor (`test/coverage_runner.rb`) and file-operation tests.

### Changed

- The runner was split into `Committer`, `Discovery` and `FileOps`; tool output
  is produced in a private mode-0700 workspace, `--dry-run` works on a private
  temporary copy, and `--in-place` preserves ownership, permissions, ACLs and
  extended attributes with the system `cp`, which is now a requirement for that
  mode.
- SECURITY.md is included in the gem, and the README gained a "Supported
  formats" section.

## [4.1.0] - 2026-06-25

### Changed

- External tools run under a wall-clock timeout and an output cap, and are
  killed as a process group when they overrun; exit codes were hardened for
  batch use.
- The README states that the `.bak` kept by `--in-place` is the original with
  all its metadata.

### Fixed

- Assorted bug fixes in the tool wrappers (see the compare link).

## [4.0.1] - 2026-06-24

### Changed

- The `--help`/`--version` banner is red instead of cyan.

## [4.0.0] - 2026-06-24

### Added

- An ASCII-art banner on `--help` and `--version`, and README instructions for
  Android (Termux).

### Changed

- Code cleanup across the library; the gemspec requirements link to each tool's
  homepage.

## [3.0.0] - 2026-06-19

### Added

- ffmpeg support for Matroska (`.mkv`/`.webm`) by lossless remux; ffmpeg is now
  the fourth required tool.
- The real-file format matrix test and CLI tests, and a "Why metaclean?"
  section in the README.

## [2.0.0] - 2026-06-18

### Added

- First release in this repository: strips metadata with ExifTool, mat2 and
  qpdf, shows a before/after diff, and offers `--inspect`, `--dry-run`,
  `--in-place`, `--recursive` and `--force`.

[Unreleased]: https://github.com/26zl/metaclean/compare/v4.3.1...HEAD
[4.3.1]: https://github.com/26zl/metaclean/compare/v4.3.0...v4.3.1
[4.3.0]: https://github.com/26zl/metaclean/compare/v4.2.0...v4.3.0
[4.2.0]: https://github.com/26zl/metaclean/compare/v4.1.0...v4.2.0
[4.1.0]: https://github.com/26zl/metaclean/compare/v4.0.1...v4.1.0
[4.0.1]: https://github.com/26zl/metaclean/compare/v4.0.0...v4.0.1
[4.0.0]: https://github.com/26zl/metaclean/compare/v3.0.0...v4.0.0
[3.0.0]: https://github.com/26zl/metaclean/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/26zl/metaclean/releases/tag/v2.0.0
