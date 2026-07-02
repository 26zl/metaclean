# frozen_string_literal: true

require_relative 'test_helper'

class CommandTest < Minitest::Test
  def test_capture3_returns_output_err_and_status
    out, err, status = Metaclean.capture3('printf', 'hi')
    assert_equal 'hi', out
    assert_equal '', err
    assert status.success?
  end

  def test_capture3_propagates_nonzero_status
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

  def test_command_timeout_honors_env_override
    with_env('METACLEAN_TIMEOUT', '300')  { assert_equal 300, Metaclean.command_timeout }
    with_env('METACLEAN_TIMEOUT', '0')    { assert_equal Metaclean::COMMAND_TIMEOUT, Metaclean.command_timeout }
    with_env('METACLEAN_TIMEOUT', 'abc')  { assert_equal Metaclean::COMMAND_TIMEOUT, Metaclean.command_timeout }
    with_env('METACLEAN_TIMEOUT', nil)    { assert_equal Metaclean::COMMAND_TIMEOUT, Metaclean.command_timeout }
  end

  def with_env(key, value)
    old = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    old.nil? ? ENV.delete(key) : ENV[key] = old
  end

  def test_capture3_caps_runaway_output_and_kills_the_command
    started = Time.now
    assert_raises(Metaclean::Error) do
      Metaclean.capture3('cat', '/dev/zero', max_output: 10_000)
    end
    assert_operator (Time.now - started), :<, 10,
                    'a flooding command must be cut off at the cap, not read forever'
  end

  def test_capture3_is_bounded_when_a_child_keeps_pipes_open
    started = Time.now
    assert_raises(Metaclean::Error) do
      Metaclean.capture3('sh', '-c', 'sleep 30 & exit 0', timeout: 0.5)
    end
    assert_operator (Time.now - started), :<, 10,
                    'a leaked child holding the pipes must not outlast the timeout'
  end

  def test_capture3_kills_the_group_and_propagates_on_interrupt
    started = Time.now
    worker = Thread.new do
      Thread.current.report_on_exception = false
      Metaclean.capture3('sleep', '30', timeout: 60)
    end
    sleep 0.5
    worker.raise(Interrupt)
    assert_raises(Interrupt) { worker.join }
    assert_operator (Time.now - started), :<, 10,
                    'an interrupt must not leave capture3 blocked on a live child'
  end
end
