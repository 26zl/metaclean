# frozen_string_literal: true

require_relative 'test_helper'

# Qpdf.rebuild! is the PDF structural pass (drops orphaned objects/old
# revisions). Pin the exit-code handling — especially the exit-3 "success with
# warnings" quirk — and the atomic temp rename / cleanup, by stubbing the
# shell-out with a fake Process::Status.
class QpdfTest < Minitest::Test
  def qpdf_temps(dir)
    # Match the SHARED marker the production code actually writes
    # (".metaclean.tmp.qpdf…"); the old literal ".metaclean.qpdf.tmp." matched
    # nothing, so a leftover-temp regression would have slipped through.
    Dir.children(dir).grep(/#{Regexp.escape(Metaclean::TMP_MARKER)}/)
  end

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
        Metaclean.stub(:capture3, writer) do
          assert_equal true, Metaclean::Qpdf.rebuild!(f)
        end
      end
      assert_equal 'REBUILT', File.read(f), 'rebuilt temp renamed over source'
      assert_empty qpdf_temps(d), 'temp cleaned up'
    end
  end

  # qpdf exit 3 = "success with warnings" — output is valid, must count as success.
  def test_exit_three_is_treated_as_success
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      File.write(f, 'ORIG')
      writer = ->(*a) { File.write(a.last, 'REBUILT'); ['', 'warning', status(false, 3)] }
      Metaclean::Qpdf.stub(:available?, true) do
        Metaclean.stub(:capture3, writer) do
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
        Metaclean.stub(:capture3, ['', 'fatal', status(false, 2)]) do
          assert_raises(Metaclean::Error) { Metaclean::Qpdf.rebuild!(f) }
        end
      end
      assert_equal 'ORIG', File.read(f), 'original untouched on failure'
      assert_empty qpdf_temps(d), 'no temp orphan'
    end
  end

  # qpdf exit 0/3 without an output file is not a usable rebuild. Treat it as
  # failure so the runner never commits a missing or stale temp.
  def test_success_exit_without_output_raises
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      File.write(f, 'ORIG')
      Metaclean::Qpdf.stub(:available?, true) do
        Metaclean.stub(:capture3, ['', '', status(true, 0)]) do
          assert_raises(Metaclean::Error) { Metaclean::Qpdf.rebuild!(f) }
        end
      end
      assert_equal 'ORIG', File.read(f)
    end
  end

  # The exit-3 ("success with warnings") branch must ALSO require an output file —
  # warnings without a produced temp is not a usable rebuild.
  def test_exit_three_without_output_raises
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      File.write(f, 'ORIG')
      Metaclean::Qpdf.stub(:available?, true) do
        Metaclean.stub(:capture3, ['', 'warning', status(false, 3)]) do
          assert_raises(Metaclean::Error) { Metaclean::Qpdf.rebuild!(f) }
        end
      end
      assert_equal 'ORIG', File.read(f), 'original untouched when exit 3 produced no output'
      assert_empty qpdf_temps(d)
    end
  end
end
