# frozen_string_literal: true

require_relative 'test_helper'

# End-to-end checks that need the real binaries. They SKIP automatically when a
# tool isn't installed (this sandbox, or CI without the tools), and run wherever
# exiftool/mat2/qpdf are present. This is the tier that exercises the actual
# strip!/read shell-outs — keep it guarded so the pure suite stays binary-free.
class IntegrationTest < Minitest::Test
  # A tiny real 16x16 JPEG (generated once with ImageMagick) embedded as base64,
  # so we can tag it with genuine GPS/Artist metadata and prove the full pipeline
  # removes it — without shipping a binary fixture or fabricating JPEG bytes.
  TINY_JPEG = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/wAALCAAQABABAREA/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAA/AKpgP//Z'

  def test_exiftool_read_returns_a_hash
    skip 'exiftool not installed' unless Metaclean::Exiftool.available?

    Dir.mktmpdir do |d|
      f = File.join(d, 'sample.txt')
      File.write(f, 'hello')
      assert_kind_of Hash, Metaclean::Exiftool.read(f)
    end
  end

  # The core promise, proven against the real binaries: a JPEG carrying real
  # GPS + author metadata comes out the other side with none, written to a
  # _clean copy. This is the tool's whole reason to exist, so it gets a fixed
  # test rather than relying on the unit suite's synthetic hashes.
  def test_real_clean_removes_privacy_metadata_end_to_end
    skip 'exiftool not installed' unless Metaclean::Exiftool.available?

    Dir.mktmpdir do |d|
      f = File.join(d, 'photo.jpg')
      File.binwrite(f, TINY_JPEG.unpack1('m0'))
      system('exiftool', '-q', '-overwrite_original',
             '-Artist=Jane Doe', '-Make=Apple',
             '-GPSLatitude=59.9139', '-GPSLatitudeRef=N',
             '-GPSLongitude=10.7522', '-GPSLongitudeRef=E', f, exception: false)

      before = Metaclean::Strategy.privacy_residual(Metaclean::Exiftool.read(f))
      refute_empty before, 'precondition: the GPS/author tags are present and flagged'

      result = nil
      capture_io { result = Metaclean::Runner.new({}).send(:clean_one, f, index: 1, total: 1) }
      refute_equal :failed, result[:status], 'a real clean of a tagged JPEG must succeed and be written'

      cleaned = File.join(d, 'photo_clean.jpg')
      assert File.exist?(cleaned), 'a _clean file is written'
      assert_empty Metaclean::Strategy.privacy_residual(Metaclean::Exiftool.read(cleaned)),
                   'no privacy tag survives a real end-to-end clean'
    end
  end

  # The ffmpeg-owned Matroska path against the real binary: a tagged mkv comes out
  # losslessly remuxed (in place) with no privacy residual. Guarded on the real
  # tools so the pure suite — and a CI runner without ffmpeg — skip it.
  def test_real_clean_strips_matroska_via_ffmpeg
    skip 'ffmpeg/exiftool not installed' unless Metaclean::Ffmpeg.available? && Metaclean::Exiftool.available?

    Dir.mktmpdir do |d|
      f = File.join(d, 'clip.mkv')
      ok = system('ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=d=1:s=64x64:r=5',
                  '-metadata', 'title=Secret Title', '-metadata', 'artist=Jane', f, exception: false)
      skip 'ffmpeg could not generate a sample mkv' unless ok && File.exist?(f)

      assert Metaclean::Exiftool.read(f).values.any? { |v| v.to_s.include?('Secret Title') },
             'precondition: the title metadata is present'

      result = nil
      capture_io { result = Metaclean::Runner.new(in_place: true).send(:clean_one, f, index: 1, total: 1) }
      assert_equal :cleaned, result[:status], 'a real mkv clean via ffmpeg must succeed and be written'

      after = Metaclean::Exiftool.read(f).values.map(&:to_s)
      refute(after.any? { |v| v.include?('Secret Title') || v.include?('Jane') },
             'no title/artist survives the ffmpeg remux')
    end
  end

  # WMV (ASF) against the real binaries: ExifTool can't write it, mat2 strips
  # Title/Author and writes a zeroed mandatory date "0000:00:00 00:00:00Z" that
  # blank_value? must treat as non-residual — otherwise a genuinely clean WMV
  # would wrongly report :failed. Guarded on mat2+exiftool+ffmpeg (to generate it).
  def test_real_clean_strips_wmv_via_mat2
    unless Metaclean::Mat2.available? && Metaclean::Exiftool.available? && Metaclean::Ffmpeg.available?
      skip 'mat2/exiftool/ffmpeg not installed'
    end

    Dir.mktmpdir do |d|
      f = File.join(d, 'clip.wmv')
      ok = system('ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=d=1:s=64x64:r=5',
                  '-c:v', 'wmv2', '-metadata', 'title=Secret WMV', '-metadata', 'author=Jane', f, exception: false)
      skip 'ffmpeg could not generate a sample wmv' unless ok && File.exist?(f)

      assert Metaclean::Exiftool.read(f).values.any? { |v| v.to_s.include?('Secret WMV') },
             'precondition: the title metadata is present'

      result = nil
      capture_io { result = Metaclean::Runner.new(in_place: true).send(:clean_one, f, index: 1, total: 1) }
      assert_equal :cleaned, result[:status], 'a real wmv clean via mat2 must succeed (zeroed ASF date is not a leak)'

      after = Metaclean::Exiftool.read(f).values.map(&:to_s)
      refute(after.any? { |v| v.include?('Secret WMV') || v.include?('Jane') },
             'no title/author survives the mat2 strip')
    end
  end
end
