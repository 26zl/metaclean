# frozen_string_literal: true

require_relative 'test_helper'

# CLI argument parsing — a malformed flag must exit non-zero with a clean
# message, never a raw OptionParser backtrace. parse! runs before the tool gate,
# so these need no exiftool/mat2/qpdf stubbing.
class CLITest < Minitest::Test
  def assert_exits(status, argv)
    err = assert_raises(SystemExit) { capture_io { Metaclean::CLI.start(argv) } }
    assert_equal status, err.status
  end

  # `--i` is an ambiguous abbreviation (matches both --inspect and --in-place),
  # so OptionParser raises AmbiguousOption — it must be handled like any other
  # parse error, not escape as a backtrace.
  def test_ambiguous_abbreviation_exits_1
    assert_exits 1, ['--i', 'x.jpg']
  end

  def test_unknown_flag_exits_1
    assert_exits 1, ['--bogus', 'x.jpg']
  end

  def test_no_args_exits_1
    assert_exits 1, []
  end
end
