# frozen_string_literal: true

require_relative 'test_helper'

class ExiftoolTest < Minitest::Test
  def status(success)
    s = Object.new
    s.define_singleton_method(:success?) { success }
    s
  end

  def test_availability_probe_is_bounded
    captured = nil
    Metaclean::Exiftool.remove_instance_variable(:@available) if Metaclean::Exiftool.instance_variable_defined?(:@available)
    Metaclean.stub(:capture3, lambda { |*args, **kwargs|
      captured = [args, kwargs]
      ['13.55', '', status(true)]
    }) do
      assert Metaclean::Exiftool.available?
    end
    assert_equal Metaclean::PROBE_TIMEOUT, captured.last[:timeout]
    assert_equal Metaclean::PROBE_MAX_OUTPUT_BYTES, captured.last[:max_output]
  ensure
    Metaclean::Exiftool.remove_instance_variable(:@available) if Metaclean::Exiftool.instance_variable_defined?(:@available)
    Metaclean::Exiftool.remove_instance_variable(:@version) if Metaclean::Exiftool.instance_variable_defined?(:@version)
  end

  def test_strip_success_returns_true
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'photo.jpg')
      File.write(file, 'bytes')
      Metaclean.stub(:capture3, ['', '', status(true)]) do
        assert_equal true, Metaclean::Exiftool.strip!(file)
      end
    end
  end

  def test_read_failure_surfaces_exiftool_error_from_json_stdout
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'mystery.bin')
      File.write(file, 'bytes')
      json = '[{"SourceFile":"mystery.bin","ExifTool:Error":"Unknown file type"}]'
      Metaclean.stub(:capture3, [json, '', status(false)]) do
        err = assert_raises(Metaclean::Error) { Metaclean::Exiftool.read(file) }
        assert_match(/Unknown file type/, err.message)
      end
    end
  end

  def test_failure_raises
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'photo.jpg')
      File.write(file, 'bytes')
      Metaclean.stub(:capture3, ['', 'boom', status(false)]) do
        assert_raises(Metaclean::Error) { Metaclean::Exiftool.strip!(file) }
      end
    end
  end

  def test_strip_also_deletes_named_tags_and_gps
    captured = nil
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'a.tiff')
      File.write(file, 'bytes')
      Metaclean.stub(:capture3, ->(*a) { captured = a; ['', '', status(true)] }) do
        Metaclean::Exiftool.strip!(file, also_delete: %w[Artist Software])
      end
    end
    assert_includes captured, '-Artist='
    assert_includes captured, '-Software='
    assert_includes captured, '-gps:all='
    assert_includes captured, '-tagsfromfile'
    assert_includes captured, '@'
    assert_includes captured, '-Orientation'
    assert_includes captured, '-ICC_Profile'
  end

  def test_unsupported_write_format_returns_soft_skip
    err = 'Error: Writing of DOCX files is not yet supported'
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'report.docx')
      File.write(file, 'bytes')
      Metaclean.stub(:capture3, ['', err, status(false)]) do
        assert_equal :unsupported, Metaclean::Exiftool.strip!(file)
      end
    end
  end

  def test_riff_and_svg_write_messages_are_soft_skips
    {
      'a.avi'  => "Error: Can't currently write RIFF AVI files",
      'a.wav'  => "Error: Can't currently write RIFF WAVE files",
      'a.svg'  => 'Error: ExifTool does not yet support writing of SVG images'
    }.each do |path, err|
      Dir.mktmpdir do |dir|
        file = File.join(dir, path)
        File.write(file, 'bytes')
        Metaclean.stub(:capture3, ['', err, status(false)]) do
          assert_equal :unsupported, Metaclean::Exiftool.strip!(file), err
        end
      end
    end
  end

  def test_generic_singular_unsupported_write_message_is_a_soft_skip
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'archive.tar')
      File.write(file, 'bytes')
      err = 'Error: Writing of this type of file is not supported'
      Metaclean.stub(:capture3, ['', err, status(false)]) do
        assert_equal :unsupported, Metaclean::Exiftool.strip!(file)
      end
    end
  end

  def test_scrub_encoding_fixes_invalid_utf8
    out = Metaclean::Exiftool.scrub_encoding(
      'UserComment' => "ab\xC3\x28cd", 'Nested' => ["x\xFFy"], 'Ok' => 'fine'
    )
    assert out['UserComment'].valid_encoding?, 'invalid bytes in a tag value must be scrubbed'
    assert out['Nested'].first.valid_encoding?, 'nested array values must be scrubbed too'
    assert_equal 'fine', out['Ok'], 'valid values pass through unchanged'
  end
end
