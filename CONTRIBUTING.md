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
bundle exec bundler-audit check --update
bundle exec ruby -Itest test/coverage_runner.rb
```

The pure unit tests run without any external tools. The integration tests in
`test/test_integration.rb` **auto-skip** unless `exiftool`, `mat2`, `qpdf`, and
`ffmpeg` are on your `PATH`; install them (see the README) to exercise the real
strip/verify flow locally. CI installs all four on Linux.

### The real-file format matrix

`test/test_format_matrix.rb` exercises every major routing family with real
files. Focused integration tests cover DNG identity tags, HTML and structured
Matroska files. Together they assert that a verified clean loses identifying
metadata while functional image/container structure remains intact. The matrix
is **opt-in** because it needs extra generators:

```bash
METACLEAN_FORMAT_MATRIX=1 bundle exec ruby -Itest test/test_format_matrix.rb
```

It needs the four cleaning tools plus `ghostscript`, `zip`/`unzip`, and either
`convert` (ImageMagick) or `cwebp` together with ffmpeg for image generation.
Any unavailable generator is reported as a skipped family. The dedicated
`format-matrix` CI job runs the whole thing on every push.

Changes to container handling must include a nested-payload fixture. In
particular, PDF/Matroska attachments and cover art may not be reported clean
unless their payload metadata is independently verified.

Release candidates are also checked manually on genuine DNG/HEIC samples,
Termux and non-POSIX filesystems.

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
