# frozen_string_literal: true

require_relative 'test_helper'

class Mat2Test < Minitest::Test
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

  def test_success_renames_cleaned_file_over_source
    ok = Object.new
    def ok.success? = true

    Dir.mktmpdir do |d|
      f = File.join(d, 'pic.jpg')
      File.write(f, 'DIRTY')
      writer = lambda do |*args|
        work = args.last
        File.write(Metaclean::Mat2.cleaned_path_for(work), 'CLEAN')
        ['', '', ok]
      end
      Metaclean::Mat2.stub(:available?, true) do
        Metaclean.stub(:capture3, writer) do
          assert_equal true, Metaclean::Mat2.strip!(f)
        end
      end
      assert_equal 'CLEAN', File.read(f), 'cleaned bytes replace the source'
      assert_empty Dir.children(d).grep(/#{Regexp.escape(Metaclean::TMP_MARKER)}/)
    end
  end

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

  def test_supported_extensions_include_mat2_document_and_archive_formats
    Metaclean::Mat2.stub(:available?, true) do
      %w[page.html archive.tar image.heic drawing.odg formula.odf].each do |path|
        assert Metaclean::Mat2.supports?(path), path
      end
    end
  end
end
