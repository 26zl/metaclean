# frozen_string_literal: true

require_relative 'test_helper'

class QpdfTest < Minitest::Test
  def qpdf_temps(dir)
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
      writer = lambda do |*args|
        if args.include?('--json-key=attachments')
          ['{"attachments":{}}', '', status(true, 0)]
        else
          File.write(args.last, 'REBUILT') unless args.include?('--check')
          ['', '', status(true, 0)]
        end
      end
      Metaclean::Qpdf.stub(:available?, true) do
        Metaclean.stub(:capture3, writer) do
          assert_equal true, Metaclean::Qpdf.rebuild!(f)
        end
      end
      assert_equal 'REBUILT', File.read(f), 'rebuilt temp renamed over source'
      assert_empty qpdf_temps(d), 'temp cleaned up'
    end
  end

  def test_exit_three_is_treated_as_success
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      File.write(f, 'ORIG')
      writer = lambda do |*args|
        if args.include?('--json-key=attachments')
          ['{"attachments":{}}', '', status(true, 0)]
        else
          File.write(args.last, 'REBUILT') unless args.include?('--check')
          ['', 'warning', status(false, 3)]
        end
      end
      Metaclean::Qpdf.stub(:available?, true) do
        Metaclean.stub(:capture3, writer) do
          assert_equal true, Metaclean::Qpdf.rebuild!(f)
        end
      end
      assert_equal 'REBUILT', File.read(f)
    end
  end

  def test_real_failure_raises_and_leaves_no_temp
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      File.write(f, 'ORIG')
      Metaclean::Qpdf.stub(:available?, true) do
        Metaclean::Qpdf.stub(:ensure_no_attachments!, true) do
          Metaclean.stub(:capture3, ['', 'fatal', status(false, 2)]) do
            assert_raises(Metaclean::Error) { Metaclean::Qpdf.rebuild!(f) }
          end
        end
      end
      assert_equal 'ORIG', File.read(f), 'original untouched on failure'
      assert_empty qpdf_temps(d), 'no temp orphan'
    end
  end

  def test_success_exit_without_output_raises
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      File.write(f, 'ORIG')
      Metaclean::Qpdf.stub(:available?, true) do
        Metaclean::Qpdf.stub(:ensure_no_attachments!, true) do
          Metaclean.stub(:capture3, ['', '', status(true, 0)]) do
            assert_raises(Metaclean::Error) { Metaclean::Qpdf.rebuild!(f) }
          end
        end
      end
      assert_equal 'ORIG', File.read(f)
    end
  end

  def test_exit_three_without_output_raises
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      File.write(f, 'ORIG')
      Metaclean::Qpdf.stub(:available?, true) do
        Metaclean::Qpdf.stub(:ensure_no_attachments!, true) do
          Metaclean.stub(:capture3, ['', 'warning', status(false, 3)]) do
            assert_raises(Metaclean::Error) { Metaclean::Qpdf.rebuild!(f) }
          end
        end
      end
      assert_equal 'ORIG', File.read(f), 'original untouched when exit 3 produced no output'
      assert_empty qpdf_temps(d)
    end
  end

  def test_pdf_with_attachments_is_rejected_before_rebuild
    Dir.mktmpdir do |d|
      file = File.join(d, 'doc.pdf')
      File.write(file, 'ORIG')
      response = ['{"attachments":{"private":{}}}', '', status(true, 0)]
      Metaclean::Qpdf.stub(:available?, true) do
        Metaclean.stub(:capture3, response) do
          error = assert_raises(Metaclean::Error) { Metaclean::Qpdf.rebuild!(file) }
          assert_match(/embedded attachments/, error.message)
        end
      end
      assert_equal 'ORIG', File.read(file)
    end
  end

  def test_structurally_invalid_rebuild_is_rejected
    Dir.mktmpdir do |d|
      file = File.join(d, 'doc.pdf')
      File.write(file, 'ORIG')
      writer = lambda do |*args|
        if args.include?('--json-key=attachments')
          ['{"attachments":{}}', '', status(true, 0)]
        elsif args.include?('--check')
          ['', 'damaged', status(false, 2)]
        else
          File.write(args.last, 'BROKEN')
          ['', '', status(true, 0)]
        end
      end
      Metaclean::Qpdf.stub(:available?, true) do
        Metaclean.stub(:capture3, writer) do
          error = assert_raises(Metaclean::Error) { Metaclean::Qpdf.rebuild!(file) }
          assert_match(/invalid PDF/, error.message)
        end
      end
      assert_equal 'ORIG', File.read(file)
    end
  end
end
