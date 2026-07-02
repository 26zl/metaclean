# frozen_string_literal: true

require_relative 'test_helper'

class CLITest < Minitest::Test
  def assert_exits(status, argv)
    err = assert_raises(SystemExit) { capture_io { Metaclean::CLI.start(argv) } }
    assert_equal status, err.status
  end

  def test_ambiguous_abbreviation_exits_1
    assert_exits 1, ['--i', 'x.jpg']
  end

  def test_unknown_flag_exits_1
    assert_exits 1, ['--bogus', 'x.jpg']
  end

  def test_no_args_exits_1
    assert_exits 1, []
  end

  def test_version_flag_exits_zero
    assert_exits 0, ['--version']
  end

  def test_help_flag_exits_zero
    assert_exits 0, ['--help']
  end

  def test_inspect_and_dry_run_are_rejected
    assert_exits 1, ['--inspect', '--dry-run', 'x.jpg']
  end

  def test_inspect_and_in_place_are_rejected
    assert_exits 1, ['--inspect', '--in-place', 'x.jpg']
  end

  def test_help_documents_privacy_output_flags
    out, = capture_io do
      assert_raises(SystemExit) { Metaclean::CLI.start(['--help']) }
    end
    assert_match(/--redact-values/, out)
    assert_match(/--show-values/, out)
    assert_match(/--quiet/, out)
    assert_match(/--allow-icc-metadata/, out)
  end
end
