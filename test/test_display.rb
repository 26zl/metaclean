# frozen_string_literal: true

require_relative 'test_helper'

class DisplayTest < Minitest::Test
  D = Metaclean::Display

  def teardown
    D.configure
  end

  def test_group_of
    assert_equal 'GPS',    D.group_of('GPS:GPSLatitude')
    assert_equal 'Artist', D.group_of('Artist')
    assert_equal 'a',      D.group_of('a:b:c')
  end

  def test_count_embedded_excludes_system_and_sourcefile
    meta = { 'SourceFile' => 'x', 'System:FileName' => 'a',
             'IFD0:Artist' => 'J', 'GPS:GPSLatitude' => 1 }
    assert_equal 2, D.count_embedded(meta)
  end

  def test_embedded_key
    assert D.embedded_key?('IFD0:Artist')
    assert D.embedded_key?('GPS:GPSLatitude')
    assert D.embedded_key?('Artist')
    refute D.embedded_key?('SourceFile')
    %w[System File ExifTool Composite].each do |g|
      refute D.embedded_key?("#{g}:Anything"), "#{g} describes the file, not embedded metadata"
    end
  end

  def test_truncate
    assert_equal 'hello', D.truncate('hello', 10)
    assert_equal 'he…',   D.truncate('hello', 3)
  end

  def test_format_value
    assert_equal '[1, 2]', D.format_value([1, 2])
    assert_equal 'a b',    D.format_value("a\n b")
    assert_equal '5',      D.format_value(5)
  end

  def test_visible_value_can_be_redacted
    D.configure(redact_values: true)
    assert_equal '[redacted]', D.visible_value('Jane Doe')
    D.configure(redact_values: false)
    assert_equal 'Jane Doe', D.visible_value('Jane Doe')
  end

  def test_format_value_handles_invalid_utf8
    bad = "ab\xC3\x28cd"
    refute bad.valid_encoding?, 'precondition: value is invalid UTF-8'
    out = D.format_value(bad)
    assert out.valid_encoding?, 'format_value must return a valid-encoding string, not raise'
  end

  def test_printable_strips_terminal_control_sequences
    out = D.printable("safe\e[31mred\a")
    refute_match(/\e|\a/, out)
    assert_match(/safe \[31mred /, out)
    refute_match(/[[:cntrl:]]/, D.printable("x#{0x9B.chr(Encoding::UTF_8)}m"))
  end

  def test_diff_classifies_removed_and_changed
    out, = capture_io do
      D.diff({ 'IFD0:Artist' => 'J', 'IFD0:Make' => 'Canon' },
             { 'IFD0:Make' => 'Nikon' })
    end
    assert_match(/Removed \(1\)/, out)
    assert_match(/Changed \(1\)/, out)
  end

  def test_diff_classifies_kept
    out, = capture_io do
      D.diff({ 'IFD0:Make' => 'Canon' }, { 'IFD0:Make' => 'Canon' })
    end
    assert_match(/Still present \(1\)/, out)
  end
end
