# frozen_string_literal: true

require_relative 'test_helper'

# Ffmpeg.strip! is the Matroska (mkv/webm) cleaner. Pin its branches — the
# lossless invocation, the success remux, and hard failure — by stubbing the
# shell-out, so a regression doesn't slip past the (skip-able) integration tier.
class FfmpegTest < Minitest::Test
  def status(success)
    s = Object.new
    s.define_singleton_method(:success?) { success }
    s
  end

  # The strip MUST be lossless: stream copy (`-c copy`) and metadata dropped
  # (`-map_metadata -1`). If these flags ever change to a re-encode, this fails.
  def test_strip_uses_lossless_copy_and_drops_metadata
    captured = nil
    Metaclean::Ffmpeg.stub(:available?, true) do
      Metaclean.stub(:capture3, ->(*a) { captured = a; ['', '', status(true)] }) do
        File.stub(:exist?, true) do
          FileUtils.stub(:mv, nil) do
            File.stub(:delete, nil) do
              assert_equal true, Metaclean::Ffmpeg.strip!('v.mkv')
            end
          end
        end
      end
    end
    assert_includes captured, '-map_metadata'
    assert_includes captured, '-1'
    assert_includes captured, '-c'
    assert_includes captured, 'copy'
    assert captured.any? { |arg| arg.start_with?('file:') && arg.end_with?('/v.mkv') },
           'input should be forced through ffmpeg file: protocol'
    assert captured.last.start_with?('file:'), 'output should be forced through ffmpeg file: protocol'
  end

  # A non-zero exit is a hard error, never a silent success.
  def test_failure_raises
    Metaclean::Ffmpeg.stub(:available?, true) do
      Metaclean.stub(:capture3, ['', 'boom', status(false)]) do
        File.stub(:exist?, false) do
          assert_raises(Metaclean::Error) { Metaclean::Ffmpeg.strip!('v.mkv') }
        end
      end
    end
  end

  # Exit 0 but no output file written → still an error, not a false success.
  def test_success_exit_but_no_output_raises
    Metaclean::Ffmpeg.stub(:available?, true) do
      Metaclean.stub(:capture3, ['', '', status(true)]) do
        File.stub(:exist?, false) do
          assert_raises(Metaclean::Error) { Metaclean::Ffmpeg.strip!('v.mkv') }
        end
      end
    end
  end
end
