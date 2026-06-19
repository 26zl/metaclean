# Contributing to metaclean

Thanks for your interest! Bug reports, fixes, and well-scoped features are all
welcome.

## Development setup

metaclean has **zero runtime gem dependencies** — it shells out to external
tools — so setup is small. You need **Ruby >= 3.2**.

```bash
git clone https://github.com/26zl/metaclean.git
cd metaclean
bundle install            # installs the dev tools (minitest, rubocop, rake)
```

## Running the tests

Always run through Bundler so you get the development dependencies and versions
declared by the Gemfile:

```bash
bundle exec rake test     # the full suite
bundle exec rubocop       # lint (must be clean)
```

The pure unit tests run without any external tools. The integration tests in
`test/test_integration.rb` **auto-skip** unless `exiftool`, `mat2`, `qpdf`, and
`ffmpeg` are on your `PATH`; install them (see the README) to exercise the real
strip/verify flow locally. CI installs all four on Linux.

### The "every format" matrix

`test/test_format_matrix.rb` generates a real sample of **every** format
metaclean routes (images, audio, video, PDF, archives, Office/OpenDocument),
cleans it, and asserts the core guarantee — a file reported `:cleaned` never
keeps its metadata (no false-clean), media stays byte-identical, and a format no
tool can clean (e.g. SVG on a mat2 build that crashes on it) fails *closed*. It
is **opt-in** (it also needs file generators and is slower), so set an env var:

```bash
METACLEAN_FORMAT_MATRIX=1 bundle exec ruby -Itest test/test_format_matrix.rb
```

It needs the four cleaning tools plus `convert` (ImageMagick), `ffmpeg`,
`ghostscript`, `zip`/`unzip`, and — for the Office formats — `soffice`
(LibreOffice). Any format whose generator is missing auto-skips. The dedicated
`format-matrix` CI job runs the whole thing on every push.

## Pull requests

- Keep the diff focused: one logical change per PR.
- Add or update a test for any behavior change — especially anything touching
  the strip/verify pipeline or the in-place/backup write path.
- `bundle exec rake test` and `bundle exec rubocop` must pass.
- Follow the existing house style (the tuned `.rubocop.yml` encodes it).

## Reporting bugs and security issues

Open an issue for ordinary bugs. For anything security- or privacy-sensitive
(e.g. a file reported clean with metadata still present), follow
[SECURITY.md](SECURITY.md) instead of filing a public issue.
