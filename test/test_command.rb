# frozen_string_literal: true

require_relative 'test_helper'

# Metaclean.capture3 is the timeout-guarded shell-out every operational tool run
# goes through. Pin the two things that matter: it behaves like Open3.capture3 on
# a normal command, and it KILLS (not just abandons) a command that runs past the
# deadline — so one hostile/corrupt file can't hang the whole batch.
class CommandTest < Minitest::Test
  def test_capture3_returns_output_err_and_status
    out, err, status = Metaclean.capture3('printf', 'hi')
    assert_equal 'hi', out
    assert_equal '', err
    assert status.success?
  end

  def test_capture3_propagates_nonzero_status
    # `false` exits 1 — capture3 must surface that, not raise.
    _out, _err, status = Metaclean.capture3('false')
    refute status.success?
  end

  def test_capture3_times_out_and_does_not_wait_for_the_command
    started = Time.now
    assert_raises(Metaclean::Error) do
      Metaclean.capture3('sleep', '30', timeout: 0.5)
    end
    assert_operator (Time.now - started), :<, 10,
                    'a timed-out command must be killed, not waited on'
  end

  # A command flooding stdout faster than the timeout (cat /dev/zero is infinite)
  # must be cut off by the byte cap and killed — not read into memory unbounded
  # and not left to run out the full timeout.
  def test_capture3_caps_runaway_output_and_kills_the_command
    started = Time.now
    assert_raises(Metaclean::Error) do
      Metaclean.capture3('cat', '/dev/zero', max_output: 10_000)
    end
    assert_operator (Time.now - started), :<, 10,
                    'a flooding command must be cut off at the cap, not read forever'
  end
end
