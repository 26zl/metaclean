# frozen_string_literal: true

require_relative 'test_helper'
require 'digest'

class FormatMatrixTest < Minitest::Test
  MARKER = 'PRIVACYMATRIXMARKER'
  TINY_JPEG = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/wAALCAAQABABAREA/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAA/AKpgP//Z'
  UNTAGGABLE_IMAGES = %w[bmp].freeze

  def setup
    skip 'set METACLEAN_FORMAT_MATRIX=1 to run the full format matrix' unless ENV['METACLEAN_FORMAT_MATRIX']

    missing = %i[Exiftool Mat2 Qpdf Ffmpeg].reject { |m| Metaclean.const_get(m).available? }
    skip "cleaning tools missing: #{missing.join(', ')}" unless missing.empty?
  end

  def test_images_clean_losslessly_without_false_clean
    unless have?('convert') || (have?('ffmpeg') && have?('cwebp'))
      skip 'no image generator (ImageMagick or ffmpeg+cwebp) installed'
    end

    tested = []
    formats = %w[jpg png gif bmp tiff webp]
    formats.each do |ext|
      Dir.mktmpdir do |d|
        f = File.join(d, "x.#{ext}")
        next unless gen_image(f)

        tested << ext
        assert still_leaks?(f), "#{ext}: metadata marker was not written" unless UNTAGGABLE_IMAGES.include?(ext)
        before = pixels(f)
        assert_clean(ext, f)
        assert_equal before, pixels(f), "#{ext}: pixels changed — clean was not lossless" if before
      end
    end
    assert_equal formats, tested, 'every listed image format must be generated and tested'
  end

  def test_audio_clean_losslessly_without_false_clean
    tested = []
    formats = %w[mp3 flac ogg opus wav aiff m4a]
    formats.each do |ext|
      Dir.mktmpdir do |d|
        f = File.join(d, "x.#{ext}")
        next unless gen_audio(f)

        tested << ext
        assert still_leaks?(f), "#{ext}: precondition — metadata marker was not written"
        before = stream_hash(f, '0:a', 'md5')
        assert_clean(ext, f)
        assert_equal before, stream_hash(f, '0:a', 'md5'), "#{ext}: audio stream changed — not lossless" if before
      end
    end
    assert_equal formats, tested, 'every listed audio format must be generated and tested'
  end

  def test_video_clean_losslessly_without_false_clean
    tested = []
    formats = %w[mp4 mov avi mkv webm wmv]
    formats.each do |ext|
      Dir.mktmpdir do |d|
        f = File.join(d, "x.#{ext}")
        next unless gen_video(f, ext)

        tested << ext
        assert still_leaks?(f), "#{ext}: precondition — metadata marker was not written"
        before = stream_hash(f, '0:v', 'framemd5')
        assert_clean(ext, f)
        assert_equal before, stream_hash(f, '0:v', 'framemd5'), "#{ext}: video stream changed — not lossless" if before
      end
    end
    assert_equal formats, tested, 'every listed video format must be generated and tested'
  end

  def test_pdf_cleans_without_false_clean
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      skip 'no PDF generator (gs/convert) available or PDF coder disabled' unless gen_pdf(f)

      assert still_leaks?(f), 'pdf: precondition — metadata marker was not written'
      assert_clean('pdf', f)
    end
  end

  def test_archives_clean_without_false_clean
    skip 'zip not installed' unless have?('zip')

    Dir.mktmpdir do |d|
      zip = File.join(d, 'a.zip')
      assert gen_zip(zip), 'could not build a zip sample'
      assert still_leaks?(zip), 'zip: precondition — the comment marker must be present before cleaning'
      assert_equal :cleaned, clean_status(zip), 'zip should clean'
      refute still_leaks?(zip), 'zip: the comment marker survived a :cleaned report (false-clean)'

      epub = File.join(d, 'b.epub')
      if gen_epub(epub)
        assert_equal :cleaned, clean_status(epub), 'epub should clean'
        refute zip_part_has_marker?(epub, 'content.opf'),
               'epub: dc:creator marker survived a :cleaned report (false-clean)'
      end

      if have?('tar')
        tar = File.join(d, 'nested.tar')
        assert gen_tar(tar), 'could not build a tar sample'
        original = File.binread(tar)
        status = clean_status(tar)
        if status == :cleaned
          refute tar_member_has_marker?(tar), 'tar: nested JPEG metadata survived'
        else
          assert_equal original, File.binread(tar), 'failed tar clean must leave the original untouched'
        end
      end

      torrent = File.join(d, 'sample.torrent')
      gen_torrent(torrent)
      assert still_leaks?(torrent), 'torrent: precondition — metadata marker must be present'
      assert_equal :cleaned, clean_status(torrent), 'torrent should clean'
      refute still_leaks?(torrent), 'torrent creator/comment survived'
    end
  end

  def test_office_documents_clean_without_false_clean
    skip 'zip not installed' unless have?('zip')

    tested = []
    formats = %w[docx xlsx pptx odt ods odp odg odf]
    formats.each do |ext|
      Dir.mktmpdir do |d|
        f = gen_office(d, ext)
        next unless f

        tested << ext
        assert office_metadata?(f), "#{ext}: precondition — identifying metadata should be present"
        assert_equal :cleaned, clean_status(f), "#{ext} should clean"
        refute office_metadata?(f), "#{ext}: document metadata survived a :cleaned report (false-clean)"
      end
    end
    assert_equal formats, tested, 'every listed Office format must be generated and tested'
  end

  def test_svg_fails_closed_never_leaks
    Dir.mktmpdir do |d|
      f = File.join(d, 'x.svg')
      File.write(f, <<~SVG)
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <metadata><dc:creator>#{MARKER}</dc:creator></metadata><rect width="10" height="10"/></svg>
      SVG
      original = File.read(f)

      status = clean_status(f)
      if status == :cleaned
        refute still_leaks?(f), 'svg reported :cleaned but the dc:creator marker survived'
      else
        assert_equal original, File.read(f), 'a failed svg clean must leave the original untouched'
      end
    end
  end

  private

  def assert_clean(ext, path)
    assert_equal :cleaned, clean_status(path), "#{ext}: expected :cleaned"
    refute still_leaks?(path), "#{ext}: FALSE-CLEAN — a metadata marker survived a :cleaned report"
  end

  def clean_status(path)
    status = nil
    capture_io { status = Metaclean::Runner.new(in_place: true).send(:clean_one, path, index: 1, total: 1)[:status] }
    status
  end

  def still_leaks?(path)
    Metaclean::Exiftool.read(path).values.any? { |v| v.to_s.include?(MARKER) }
  rescue Metaclean::Error
    false
  end

  def have?(cmd)
    ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, cmd)) }
  end

  def sh(*)
    system(*, %i[out err] => File::NULL)
  end

  def made?(path)
    File.exist?(path) && File.size(path).positive?
  end

  def pixels(path)
    command = if have?('convert')
                ['convert', path, '-depth', '8', 'RGBA:-']
              else
                ['ffmpeg', '-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', 'rgba', '-']
              end
    out = IO.popen(command, 'rb', err: File::NULL, &:read)
    out && !out.empty? ? Digest::MD5.hexdigest(out) : nil
  rescue StandardError
    nil
  end

  def stream_hash(path, map, fmt)
    out = IO.popen(['ffmpeg', '-v', 'error', '-i', path, '-map', map, '-f', fmt, '-'], 'rb', err: File::NULL, &:read)
    out && !out.empty? ? Digest::MD5.hexdigest(out.gsub(/^#.*$/, '')) : nil
  rescue StandardError
    nil
  end

  def gen_image(path)
    generated = if have?('convert')
                  sh('convert', '-size', '32x32', 'gradient:red-blue', path)
                elsif File.extname(path) == '.webp'
                  ppm = "#{path}.ppm"
                  ok = sh('ffmpeg', '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=s=32x32:d=0.1',
                          '-frames:v', '1', ppm)
                  ok && sh('cwebp', '-quiet', ppm, '-o', path)
                else
                  sh('ffmpeg', '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=s=32x32:d=0.1',
                     '-frames:v', '1', path)
                end
    return unless generated && made?(path)

    tagged = sh('exiftool', '-q', '-overwrite_original', "-Artist=#{MARKER}", "-XMP-dc:Creator=#{MARKER}",
                "-Comment=#{MARKER}", '-GPSLatitude=59.9', '-GPSLatitudeRef=N',
                '-GPSLongitude=10.7', '-GPSLongitudeRef=E', path)
    return path if UNTAGGABLE_IMAGES.include?(Metaclean.ext_of(path))

    path if tagged && still_leaks?(path)
  end

  def gen_audio(path)
    return unless have?('ffmpeg')

    sh('ffmpeg', '-y', '-v', 'error', '-f', 'lavfi', '-i', 'sine=f=440:d=1',
       '-metadata', "title=#{MARKER}", '-metadata', "artist=#{MARKER}", path)
    path if made?(path)
  end

  def gen_video(path, ext)
    return unless have?('ffmpeg')

    extra = ext == 'wmv' ? ['-c:v', 'wmv2'] : []
    sh('ffmpeg', '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=d=1:s=64x64:r=5',
       *extra, '-metadata', "title=#{MARKER}", '-metadata', "artist=#{MARKER}", path)
    path if made?(path)
  end

  def gen_pdf(path)
    if have?('gs')
      sh('gs', '-q', '-dNOPAUSE', '-dBATCH', '-sDEVICE=pdfwrite', "-sOutputFile=#{path}", '-c', 'showpage')
    elsif have?('convert')
      sh('convert', '-size', '64x64', 'xc:white', path)
    end
    return unless made?(path)

    sh('exiftool', '-q', '-overwrite_original', "-Author=#{MARKER}", "-Title=#{MARKER}", path)
    path if made?(path)
  end

  def gen_zip(path)
    Dir.mktmpdir do |t|
      File.write(File.join(t, 'f.txt'), 'data')
      sh('zip', '-jq', path, File.join(t, 'f.txt'))
    end
    return unless made?(path)

    IO.popen(['zip', '-z', path], 'w', out: File::NULL, err: File::NULL) { |io| io.puts MARKER }
    path if made?(path)
  end

  def gen_epub(path)
    Dir.mktmpdir do |t|
      File.write(File.join(t, 'mimetype'), 'application/epub+zip')
      FileUtils.mkdir_p(File.join(t, 'META-INF'))
      File.write(File.join(t, 'META-INF', 'container.xml'),
                 '<?xml version="1.0"?><container version="1.0" ' \
                 'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>' \
                 '<rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>' \
                 '</rootfiles></container>')
      File.write(File.join(t, 'content.opf'),
                 '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" ' \
                 'unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">' \
                 "<dc:title>#{MARKER}</dc:title><dc:creator>#{MARKER}</dc:creator>" \
                 '<dc:identifier id="id">x</dc:identifier><dc:language>en</dc:language></metadata>' \
                 '<manifest><item id="t" href="t.html" media-type="application/xhtml+xml"/></manifest>' \
                 '<spine><itemref idref="t"/></spine></package>')
      File.write(File.join(t, 't.html'), '<html><body>hi</body></html>')
      Dir.chdir(t) do
        sh('zip', '-X0q', path, 'mimetype')
        sh('zip', '-Xrq', path, 'META-INF', 'content.opf', 't.html')
      end
    end
    path if made?(path)
  end

  def gen_tar(path)
    Dir.mktmpdir do |dir|
      image = File.join(dir, 'private.jpg')
      File.binwrite(image, TINY_JPEG.unpack1('m0'))
      sh('exiftool', '-q', '-overwrite_original', "-Artist=#{MARKER}",
         "-GPSLatitude=59.9", '-GPSLatitudeRef=N',
         '-GPSLongitude=10.7', '-GPSLongitudeRef=E', image)
      sh('tar', '-cf', path, '-C', dir, 'private.jpg')
    end
    path if made?(path)
  end

  def gen_torrent(path)
    info = 'd6:lengthi1e4:name5:x.txt12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaae'
    data = "d8:announce14:https://x.test10:created by#{MARKER.bytesize}:#{MARKER}" \
           "7:comment#{MARKER.bytesize}:#{MARKER}4:info#{info}e"
    File.binwrite(path, data)
  end

  def gen_office(dir, ext)
    %w[docx xlsx pptx].include?(ext) ? gen_ooxml(dir, ext) : gen_opendocument(dir, ext)
  end

  def gen_ooxml(dir, ext)
    root = File.join(dir, 'package')
    part, content_type, body = ooxml_main_part(ext)
    FileUtils.mkdir_p(File.join(root, File.dirname(part)))
    FileUtils.mkdir_p(File.join(root, '_rels'))
    FileUtils.mkdir_p(File.join(root, 'docProps'))
    File.write(File.join(root, part), body)
    File.write(File.join(root, '[Content_Types].xml'), ooxml_content_types(part, content_type))
    File.write(File.join(root, '_rels', '.rels'), ooxml_relationships(part))
    File.write(File.join(root, 'docProps', 'core.xml'), ooxml_core_properties)
    out = File.join(dir, "sample.#{ext}")
    Dir.chdir(root) { sh('zip', '-Xrq', out, '.') }
    made?(out) ? out : nil
  end

  def ooxml_main_part(ext)
    case ext
    when 'docx'
      ['word/document.xml', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml',
       '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' \
       '<w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body></w:document>']
    when 'xlsx'
      ['xl/workbook.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml',
       '<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets/></workbook>']
    when 'pptx'
      ['ppt/presentation.xml', 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml',
       '<?xml version="1.0"?><p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' \
       '<p:sldIdLst/></p:presentation>']
    end
  end

  def ooxml_content_types(part, content_type)
    %(<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) \
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' \
      '<Default Extension="xml" ContentType="application/xml"/>' \
      "<Override PartName=\"/#{part}\" ContentType=\"#{content_type}\"/>" \
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>' \
      '</Types>'
  end

  def ooxml_relationships(part)
    %(<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) \
      "<Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" " \
      "Target=\"#{part}\"/>" \
      '<Relationship Id="r2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" ' \
      'Target="docProps/core.xml"/></Relationships>'
  end

  def ooxml_core_properties
    %(<?xml version="1.0"?><cp:coreProperties ) \
      'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ' \
      'xmlns:dc="http://purl.org/dc/elements/1.1/">' \
      "<dc:title>#{MARKER}</dc:title><dc:creator>#{MARKER}</dc:creator></cp:coreProperties>"
  end

  def gen_opendocument(dir, ext)
    mime = {
      'odt' => 'text', 'ods' => 'spreadsheet', 'odp' => 'presentation',
      'odg' => 'graphics', 'odf' => 'formula'
    }.fetch(ext)
    root = File.join(dir, 'package')
    FileUtils.mkdir_p(File.join(root, 'META-INF'))
    File.write(File.join(root, 'mimetype'), "application/vnd.oasis.opendocument.#{mime}")
    File.write(File.join(root, 'content.xml'), odf_content)
    File.write(File.join(root, 'meta.xml'), odf_metadata)
    File.write(File.join(root, 'META-INF', 'manifest.xml'), odf_manifest(mime))
    out = File.join(dir, "sample.#{ext}")
    Dir.chdir(root) do
      sh('zip', '-X0q', out, 'mimetype')
      sh('zip', '-Xrq', out, 'META-INF', 'content.xml', 'meta.xml')
    end
    made?(out) ? out : nil
  end

  def odf_content
    '<?xml version="1.0"?><office:document-content ' \
      'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" ' \
      'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">' \
      '<office:body><office:text><text:p>Hello</text:p></office:text></office:body></office:document-content>'
  end

  def odf_metadata
    '<?xml version="1.0"?><office:document-meta ' \
      'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" ' \
      'xmlns:dc="http://purl.org/dc/elements/1.1/" ' \
      'xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0">' \
      "<office:meta><dc:title>#{MARKER}</dc:title><meta:initial-creator>#{MARKER}</meta:initial-creator>" \
      '</office:meta></office:document-meta>'
  end

  def odf_manifest(mime)
    '<?xml version="1.0"?><manifest:manifest ' \
      'xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0">' \
      "<manifest:file-entry manifest:full-path=\"/\" " \
      "manifest:media-type=\"application/vnd.oasis.opendocument.#{mime}\"/>" \
      '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>' \
      '<manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>' \
      '</manifest:manifest>'
  end

  def office_metadata?(path)
    parts = IO.popen(['unzip', '-p', path, 'docProps/core.xml', 'docProps/app.xml', 'meta.xml'],
                     'rb', err: File::NULL, &:read).to_s
    parts.include?(MARKER) || parts.match?(/LibreOffice|dcterms|meta:generation|meta:creation-date|dc:date/)
  rescue StandardError
    false
  end

  def zip_part_has_marker?(path, entry)
    out = IO.popen(['unzip', '-p', path, entry], 'rb', err: File::NULL, &:read).to_s
    out.include?(MARKER)
  rescue StandardError
    false
  end

  def tar_member_has_marker?(path)
    Dir.mktmpdir do |dir|
      return true unless sh('tar', '-xf', path, '-C', dir)

      return still_leaks?(File.join(dir, 'private.jpg'))
    end
  end
end
