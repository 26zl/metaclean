# frozen_string_literal: true

require_relative 'test_helper'

# Exiftool.strip! is the actual metadata removal. Pin its branches — the primary
# strip, the --keep-* preserve fallback, and hard failure — deterministically by
# stubbing the shell-out, so a regression doesn't slip past the (skip-able)
# integration tier.
class ExiftoolTest < Minitest::Test
  def status(success)
    s = Object.new
    s.define_singleton_method(:success?) { success }
    s
  end

  def test_strip_success_returns_true
    Metaclean::Exiftool.stub(:available?, true) do
      Open3.stub(:capture3, ['', '', status(true)]) do
        assert_equal true, Metaclean::Exiftool.strip!('photo.jpg')
      end
    end
  end

  # Generic failure → hard error, never a silent success.
  def test_failure_raises
    Metaclean::Exiftool.stub(:available?, true) do
      Open3.stub(:capture3, ['', 'boom', status(false)]) do
        assert_raises(Metaclean::Error) { Metaclean::Exiftool.strip!('photo.jpg') }
      end
    end
  end

  # also_delete: names are passed to ExifTool as `-Tag=` (so IFD0 tags `-all=`
  # leaves on TIFF still get removed), and the GPS group is always cleared.
  def test_strip_also_deletes_named_tags_and_gps
    captured = nil
    Metaclean::Exiftool.stub(:available?, true) do
      Open3.stub(:capture3, ->(*a) { captured = a; ['', '', status(true)] }) do
        Metaclean::Exiftool.strip!('a.tiff', also_delete: %w[Artist Software])
      end
    end
    assert_includes captured, '-Artist='
    assert_includes captured, '-Software='
    assert_includes captured, '-gps:all='
  end

  # A format ExifTool can read but not write (docx/odt/…) reports :unsupported —
  # a soft skip for the runner — instead of raising, so mat2 (the authority for
  # those formats) can still produce a confident clean.
  def test_unsupported_write_format_returns_soft_skip
    err = 'Error: Writing of DOCX files is not yet supported'
    Metaclean::Exiftool.stub(:available?, true) do
      Open3.stub(:capture3, ['', err, status(false)]) do
        assert_equal :unsupported, Metaclean::Exiftool.strip!('report.docx')
      end
    end
  end

  # ExifTool can read but not write RIFF (avi/wav) and SVG — mat2 owns those
  # strips. Each phrasing must read as a soft skip, so a file mat2 cleans isn't
  # wrongly pinned at :unverified by an exiftool "failure" it was never going to
  # avoid.
  def test_riff_and_svg_write_messages_are_soft_skips
    {
      'a.avi'  => "Error: Can't currently write RIFF AVI files",
      'a.wav'  => "Error: Can't currently write RIFF WAVE files",
      'a.svg'  => 'Error: ExifTool does not yet support writing of SVG images'
    }.each do |path, err|
      Metaclean::Exiftool.stub(:available?, true) do
        Open3.stub(:capture3, ['', err, status(false)]) do
          assert_equal :unsupported, Metaclean::Exiftool.strip!(path), err
        end
      end
    end
  end

  # ExifTool -j can carry invalid UTF-8 in odd/binary tag values; read scrubs them
  # (recursively) so the display/JSON layers can't crash the run on hostile bytes.
  def test_scrub_encoding_fixes_invalid_utf8
    out = Metaclean::Exiftool.scrub_encoding(
      'UserComment' => "ab\xC3\x28cd", 'Nested' => ["x\xFFy"], 'Ok' => 'fine'
    )
    assert out['UserComment'].valid_encoding?, 'invalid bytes in a tag value must be scrubbed'
    assert out['Nested'].first.valid_encoding?, 'nested array values must be scrubbed too'
    assert_equal 'fine', out['Ok'], 'valid values pass through unchanged'
  end
end
