# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'digest'

class IntegrationTest < Minitest::Test
  TINY_JPEG = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/wAALCAAQABABAREA/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAA/AKpgP//Z'

  def test_exiftool_read_returns_a_hash
    skip 'exiftool not installed' unless Metaclean::Exiftool.available?

    Dir.mktmpdir do |d|
      f = File.join(d, 'sample.txt')
      File.write(f, 'hello')
      assert_kind_of Hash, Metaclean::Exiftool.read(f)
    end
  end

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
      assert_equal :cleaned, result[:status], 'a real clean of a tagged JPEG must be verified'

      cleaned = File.join(d, 'photo_clean.jpg')
      assert File.exist?(cleaned), 'a _clean file is written'
      assert_empty Metaclean::Strategy.privacy_residual(Metaclean::Exiftool.read(cleaned)),
                   'no privacy tag survives a real end-to-end clean'
    end
  end

  def test_jpeg_preserves_orientation_while_removing_identity
    skip 'exiftool not installed' unless Metaclean::Exiftool.available?

    Dir.mktmpdir do |d|
      file = File.join(d, 'oriented.jpg')
      File.binwrite(file, TINY_JPEG.unpack1('m0'))
      system('exiftool', '-q', '-overwrite_original', '-Orientation#=6', '-Artist=Jane', file, exception: true)

      result = nil
      capture_io { result = Metaclean::Runner.new({}).send(:clean_one, file, index: 1, total: 1) }
      assert_equal :cleaned, result[:status]

      after = Metaclean::Exiftool.read(File.join(d, 'oriented_clean.jpg'))
      assert_equal 6, after['IFD0:Orientation']
      refute after.key?('IFD0:Artist')
    end
  end

  def test_jpeg_standard_icc_profile_is_cleaned_by_default
    skip 'exiftool not installed' unless Metaclean::Exiftool.available?

    profile = Dir[
      '/System/Library/ColorSync/Profiles/sRGB Profile.icc',
      '/usr/share/color/icc/**/sRGB*.icc',
      '/usr/share/color/icc/**/*sRGB*.icc'
    ].first
    skip 'no standard sRGB ICC profile fixture available' unless profile

    Dir.mktmpdir do |d|
      file = File.join(d, 'profiled.jpg')
      File.binwrite(file, TINY_JPEG.unpack1('m0'))
      system('exiftool', '-q', '-overwrite_original', "-ICC_Profile<=#{profile}", '-Artist=Jane', file, exception: true)

      result = nil
      capture_io { result = Metaclean::Runner.new({}).send(:clean_one, file, index: 1, total: 1) }
      assert_equal :cleaned, result[:status], 'a standard sRGB profile is not identifying and must not block a clean'

      after = Metaclean::Exiftool.read(File.join(d, 'profiled_clean.jpg'))
      assert(after.keys.any? { |key| key.start_with?('ICC') }, 'the color profile is retained')
      refute after.key?('IFD0:Artist'), 'identifying EXIF is still removed'
    end
  end

  def test_dng_identifiers_do_not_survive_a_cleaned_report
    skip 'ffmpeg/exiftool not installed' unless Metaclean::Ffmpeg.available? && Metaclean::Exiftool.available?

    Dir.mktmpdir do |d|
      tiff = File.join(d, 'raw.tiff')
      dng = File.join(d, 'raw.dng')
      system('ffmpeg', '-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=gray:s=32x32',
             '-frames:v', '1', tiff, exception: true)
      File.rename(tiff, dng)
      system(
        'exiftool', '-q', '-overwrite_original',
        '-DNGVersion=1.4.0.0', '-DNGBackwardVersion=1.1.0.0',
        '-UniqueCameraModel=JanePrivateCamera', '-CameraSerialNumber=SECRET123',
        '-OriginalRawFileName=Jane_secret.dng',
        '-RawDataUniqueID=00112233445566778899aabbccddeeff', dng,
        exception: true
      )
      pixels_before = decoded_video_hash(dng)

      result = nil
      capture_io { result = Metaclean::Runner.new({}).send(:clean_one, dng, index: 1, total: 1) }
      assert_equal :cleaned, result[:status]
      after = Metaclean::Exiftool.read(File.join(d, 'raw_clean.dng'))
      sensitive = /UniqueCameraModel|CameraSerialNumber|OriginalRawFileName|RawDataUniqueID/
      assert_empty(after.select { |key, _| key.match?(sensitive) })
      assert_equal pixels_before, decoded_video_hash(File.join(d, 'raw_clean.dng'))
    end
  end

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

  def test_matroska_with_attachments_fails_closed
    skip 'ffmpeg/exiftool not installed' unless Metaclean::Ffmpeg.available? && Metaclean::Exiftool.available?

    Dir.mktmpdir do |d|
      metadata = File.join(d, 'chapters.txt')
      attachment = File.join(d, 'Jane-private.ttf')
      file = File.join(d, 'structured.mkv')
      File.write(metadata, <<~META)
        ;FFMETADATA1
        title=Private
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=1000
        title=Secret Chapter
      META
      File.write(attachment, 'fontdata')
      system(
        'ffmpeg', '-y', '-v', 'error',
        '-f', 'lavfi', '-i', 'color=c=black:s=32x32:d=1',
        '-f', 'ffmetadata', '-i', metadata,
        '-map', '0:v', '-map_metadata', '1', '-map_chapters', '1',
        '-metadata:s:v:0', 'language=eng', '-metadata:s:v:0', 'title=Jane Track',
        '-c:v', 'ffv1', '-attach', attachment,
        '-metadata:s:t', 'mimetype=application/x-truetype-font',
        '-metadata:s:t', 'filename=Jane-private.ttf',
        '-metadata:s:t', 'title=Private Font', file,
        exception: true
      )
      original = File.binread(file)

      result = nil
      capture_io { result = Metaclean::Runner.new(in_place: true).send(:clean_one, file, index: 1, total: 1) }
      assert_equal :failed, result[:status]
      assert_equal original, File.binread(file)
      refute File.exist?("#{file}.bak")
    end
  end

  def test_matroska_with_metadata_bearing_image_attachment_fails_closed
    skip 'ffmpeg/exiftool not installed' unless Metaclean::Ffmpeg.available? && Metaclean::Exiftool.available?

    Dir.mktmpdir do |dir|
      attachment = File.join(dir, 'cover.jpg')
      file = File.join(dir, 'cover.mkv')
      File.binwrite(attachment, TINY_JPEG.unpack1('m0'))
      system('exiftool', '-q', '-overwrite_original', '-Artist=Jane',
             '-GPSLatitude=59.9', '-GPSLatitudeRef=N',
             '-GPSLongitude=10.7', '-GPSLongitudeRef=E', attachment, exception: true)
      system('ffmpeg', '-y', '-v', 'error', '-f', 'lavfi',
             '-i', 'color=c=black:s=32x32:d=1', '-c:v', 'ffv1',
             '-attach', attachment, '-metadata:s:t', 'mimetype=image/jpeg',
             '-metadata:s:t', 'filename=cover.jpg', file, exception: true)
      original = File.binread(file)

      result = nil
      capture_io { result = Metaclean::Runner.new(in_place: true).send(:clean_one, file, index: 1, total: 1) }
      assert_equal :failed, result[:status]
      assert_equal original, File.binread(file)
      refute File.exist?("#{file}.bak")
    end
  end

  def test_pdf_with_metadata_bearing_attachment_fails_closed
    required = Metaclean::Qpdf.available? && Metaclean::Exiftool.available? && system('which', 'gs', out: File::NULL)
    skip 'qpdf/exiftool/ghostscript not installed' unless required

    Dir.mktmpdir do |dir|
      base = File.join(dir, 'base.pdf')
      attachment = File.join(dir, 'secret.jpg')
      file = File.join(dir, 'attached.pdf')
      system('gs', '-q', '-dNOPAUSE', '-dBATCH', '-sDEVICE=pdfwrite',
             "-sOutputFile=#{base}", '-c', 'showpage', exception: true)
      File.binwrite(attachment, TINY_JPEG.unpack1('m0'))
      system('exiftool', '-q', '-overwrite_original', '-Artist=Jane',
             '-GPSLatitude=59.9', '-GPSLatitudeRef=N',
             '-GPSLongitude=10.7', '-GPSLongitudeRef=E', attachment, exception: true)
      system('qpdf', base, '--add-attachment', attachment, '--key=private',
             '--filename=secret.jpg', '--', file, exception: true)
      original = File.binread(file)

      result = nil
      capture_io { result = Metaclean::Runner.new(in_place: true).send(:clean_one, file, index: 1, total: 1) }
      assert_equal :unverified, result[:status]
      assert_equal original, File.binread(file)
      refute File.exist?("#{file}.bak")
    end
  end

  def test_in_place_preserves_extended_attributes_on_macos
    skip 'macOS xattr test' unless RUBY_PLATFORM.include?('darwin') && File.executable?('/usr/bin/xattr')

    Dir.mktmpdir do |dir|
      file = File.join(dir, 'tagged.jpg')
      File.binwrite(file, TINY_JPEG.unpack1('m0'))
      system('exiftool', '-q', '-overwrite_original', '-Artist=Jane', file, exception: true)
      system('/usr/bin/xattr', '-w', 'com.metaclean.test', 'preserve-me', file, exception: true)
      system('chmod', '+a', 'everyone deny execute', file, exception: true)
      acl_before = IO.popen(['ls', '-le', file], &:read).lines.drop(1).map(&:strip)

      result = nil
      output, = capture_io do
        result = Metaclean::Runner.new(in_place: true).send(:clean_one, file, index: 1, total: 1)
      end
      assert_equal :cleaned, result[:status]
      assert_includes output, "Backup with original metadata: #{file}.bak"
      value = IO.popen(['/usr/bin/xattr', '-p', 'com.metaclean.test', file], &:read).strip
      assert_equal 'preserve-me', value
      assert_equal acl_before, IO.popen(['ls', '-le', file], &:read).lines.drop(1).map(&:strip)
    end
  end

  def test_in_place_preserves_linux_acl_and_extended_attributes
    needed = %w[setfattr getfattr setfacl getfacl]
    skip 'Linux attr/acl tools not installed' unless RUBY_PLATFORM.include?('linux') && needed.all? { |tool| executable?(tool) }

    Dir.mktmpdir do |dir|
      file = File.join(dir, 'tagged.jpg')
      File.binwrite(file, TINY_JPEG.unpack1('m0'))
      system('exiftool', '-q', '-overwrite_original', '-Artist=Jane', file, exception: true)
      system('setfattr', '-n', 'user.metaclean.test', '-v', 'preserve-me', file, exception: true)
      system('setfacl', '-m', "u:#{Process.uid}:rw", file, exception: true)
      acl_before = IO.popen(['getfacl', '-cp', file], &:read)

      result = nil
      capture_io { result = Metaclean::Runner.new(in_place: true).send(:clean_one, file, index: 1, total: 1) }
      assert_equal :cleaned, result[:status]
      value = IO.popen(['getfattr', '--only-values', '-n', 'user.metaclean.test', file], &:read).strip
      assert_equal 'preserve-me', value
      assert_equal acl_before, IO.popen(['getfacl', '-cp', file], &:read)
    end
  end

  def test_html_is_cleaned_by_mat2_instead_of_succeeding_as_unsupported
    skip 'mat2/exiftool not installed' unless Metaclean::Mat2.available? && Metaclean::Exiftool.available?

    Dir.mktmpdir do |d|
      file = File.join(d, 'private.html')
      File.write(file, '<html><head><title>Secret</title>' \
                       '<meta name="author" content="Jane" /></head><body>Hello</body></html>')
      result = nil
      capture_io { result = Metaclean::Runner.new({}).send(:clean_one, file, index: 1, total: 1) }
      assert_equal :cleaned, result[:status]
      cleaned = File.read(File.join(d, 'private_clean.html'))
      refute_match(/Secret|Jane|author/, cleaned)
    end
  end

  def test_css_author_comment_is_removed
    skip 'mat2/exiftool not installed' unless Metaclean::Mat2.available? && Metaclean::Exiftool.available?

    Dir.mktmpdir do |dir|
      file = File.join(dir, 'private.css')
      File.write(file, "/* Author: Jane Secret */\nbody { color: red; }\n")
      result = nil
      capture_io { result = Metaclean::Runner.new({}).send(:clean_one, file, index: 1, total: 1) }
      assert_equal :cleaned, result[:status]
      cleaned = File.read(File.join(dir, 'private_clean.css'))
      refute_match(/Jane|Author/, cleaned)
      assert_match(/color: red/, cleaned)
    end
  end

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

  private

  def decoded_video_hash(path)
    output = IO.popen(
      ['ffmpeg', '-v', 'error', '-i', path, '-map', '0:v:0', '-f', 'framemd5', '-'],
      'rb', err: File::NULL, &:read
    )
    raise "ffmpeg could not decode #{path}" if output.empty?

    Digest::SHA256.hexdigest(output.lines.reject { |line| line.start_with?('#') }.join)
  end

  def executable?(name)
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |directory|
      !directory.empty? && File.executable?(File.join(directory, name))
    end
  end
end
