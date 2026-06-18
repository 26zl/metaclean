# frozen_string_literal: true

require_relative 'test_helper'

# Qpdf.rebuild! is the PDF structural pass (drops orphaned objects/old
# revisions). Pin the exit-code handling — especially the exit-3 "success with
# warnings" quirk — and the atomic temp rename / cleanup, by stubbing the
# shell-out with a fake Process::Status.
class QpdfTest < Minitest::Test
  def status(success, code)
    s = Object.new
    s.define_singleton_method(:success?) { success }
    s.define_singleton_method(:exitstatus) { code }
    s
  end

  def test_exit_zero_rebuilds_and_returns_true
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      File.write(f, 'ORIG')
      writer = ->(*a) { File.write(a.last, 'REBUILT'); ['', '', status(true, 0)] }
      Metaclean::Qpdf.stub(:available?, true) do
        Open3.stub(:capture3, writer) do
          assert_equal true, Metaclean::Qpdf.rebuild!(f)
        end
      end
      assert_equal 'REBUILT', File.read(f), 'rebuilt temp renamed over source'
      assert_empty Dir.glob(File.join(d, '*.qpdf.tmp.*')), 'temp cleaned up'
    end
  end

  # qpdf exit 3 = "success with warnings" — output is valid, must count as success.
  def test_exit_three_is_treated_as_success
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      File.write(f, 'ORIG')
      writer = ->(*a) { File.write(a.last, 'REBUILT'); ['', 'warning', status(false, 3)] }
      Metaclean::Qpdf.stub(:available?, true) do
        Open3.stub(:capture3, writer) do
          assert_equal true, Metaclean::Qpdf.rebuild!(f)
        end
      end
      assert_equal 'REBUILT', File.read(f)
    end
  end

  # A real failure (exit 2) raises and leaves the original intact with no temp.
  def test_real_failure_raises_and_leaves_no_temp
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      File.write(f, 'ORIG')
      Metaclean::Qpdf.stub(:available?, true) do
        Open3.stub(:capture3, ['', 'fatal', status(false, 2)]) do
          assert_raises(Metaclean::Error) { Metaclean::Qpdf.rebuild!(f) }
        end
      end
      assert_equal 'ORIG', File.read(f), 'original untouched on failure'
      assert_empty Dir.glob(File.join(d, '*.qpdf.tmp.*')), 'no temp orphan'
    end
  end
end
