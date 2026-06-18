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
end
