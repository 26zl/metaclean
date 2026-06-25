# frozen_string_literal: true

require_relative 'test_helper'

# mat2's soft-skip mechanism — what prevents a false-clean when mat2 cannot
# handle a file — pinned deterministically by stubbing the shell-out. This used
# to be an integration test on a `.txt` file, but which extensions a given mat2
# build supports is not stable (real mat2 happily "cleans" plain text), so the
# behaviour is tested at the message-parsing layer instead.
class Mat2Test < Minitest::Test
  # A non-zero exit whose output matches the "unsupported" pattern → :unsupported
  # (a soft skip the runner continues past), NOT true — which would let the file
  # be reported cleaned while metadata is still embedded.
  def test_unsupported_message_is_a_soft_skip
    failed = Object.new
    def failed.success? = false

    Dir.mktmpdir do |d|
      f = File.join(d, 'note.bin')
      File.write(f, 'x')
      Metaclean::Mat2.stub(:available?, true) do
        Metaclean.stub(:capture3, ['', 'note.bin: this file type is not supported', failed]) do
          assert_equal :unsupported, Metaclean::Mat2.strip!(f)
        end
      end
    end
  end

  # A non-zero exit that is NOT an "unsupported" message is a hard failure, so it
  # is never mistaken for a clean.
  def test_other_failure_raises
    failed = Object.new
    def failed.success? = false

    Dir.mktmpdir do |d|
      f = File.join(d, 'note.bin')
      File.write(f, 'x')
      Metaclean::Mat2.stub(:available?, true) do
        Metaclean.stub(:capture3, ['', 'mat2: internal error', failed]) do
          assert_raises(Metaclean::Error) { Metaclean::Mat2.strip!(f) }
        end
      end
    end
  end

  # Success path: mat2 wrote <name>.cleaned.<ext> → it is renamed over the
  # source (mat2's core job) and true returned, with no orphan left.
  def test_success_renames_cleaned_file_over_source
    ok = Object.new
    def ok.success? = true

    Dir.mktmpdir do |d|
      f = File.join(d, 'pic.jpg')
      File.write(f, 'DIRTY')
      cleaned = File.join(d, 'pic.cleaned.jpg')
      writer = ->(*_a) { File.write(cleaned, 'CLEAN'); ['', '', ok] }
      Metaclean::Mat2.stub(:available?, true) do
        Metaclean.stub(:capture3, writer) do
          assert_equal true, Metaclean::Mat2.strip!(f)
        end
      end
      assert_equal 'CLEAN', File.read(f), 'cleaned bytes replace the source'
      refute File.exist?(cleaned), 'no orphan .cleaned file remains'
    end
  end

  # Success but no cleaned file written → nothing to strip → :no_metadata, source
  # left untouched.
  def test_success_without_cleaned_file_is_no_metadata
    ok = Object.new
    def ok.success? = true

    Dir.mktmpdir do |d|
      f = File.join(d, 'pic.jpg')
      File.write(f, 'ORIG')
      Metaclean::Mat2.stub(:available?, true) do
        Metaclean.stub(:capture3, ['', '', ok]) do
          assert_equal :no_metadata, Metaclean::Mat2.strip!(f)
        end
      end
      assert_equal 'ORIG', File.read(f)
    end
  end
end
