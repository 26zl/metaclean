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
`test/test_integration.rb` **auto-skip** unless `exiftool`, `mat2`, and `qpdf`
are on your `PATH`; install them (see the README) to exercise the real
strip/verify flow locally. CI installs all three on Linux.

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
