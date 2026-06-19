# frozen_string_literal: true

require_relative 'test_helper'
require 'digest'

# The "every format" matrix, end-to-end against the REAL binaries. For each
# format metaclean routes, it generates a sample carrying real metadata, cleans
# it in place, and checks the core guarantees:
#
#   * NO FALSE-CLEAN: a file reported :cleaned must have its identifying metadata
#     actually gone — the worst-case failure for a privacy tool.
#   * The formats we commit to (images, audio, video, pdf, archives, documents)
#     reach :cleaned, and media stays byte-identical (lossless).
#   * A format no installed tool can clean (e.g. SVG on a mat2 build that crashes
#     on it) FAILS CLOSED (:failed, original untouched) rather than leaking.
#
# It is OPT-IN: it needs extra generators (ImageMagick/ffmpeg/ghostscript/soffice)
# on top of the four cleaning tools and is slower than the pure suite, so it only
# runs when METACLEAN_FORMAT_MATRIX is set (the dedicated CI job sets it). Every
# format auto-skips if the generator it needs is missing, so it never fails
# spuriously — and each family test refuses to pass vacuously (asserts it tested
# at least one format).
class FormatMatrixTest < Minitest::Test
  MARKER = 'PRIVACYMATRIXMARKER'

  def setup
    skip 'set METACLEAN_FORMAT_MATRIX=1 to run the full format matrix' unless ENV['METACLEAN_FORMAT_MATRIX']

    missing = %i[Exiftool Mat2 Qpdf Ffmpeg].reject { |m| Metaclean.const_get(m).available? }
    skip "cleaning tools missing: #{missing.join(', ')}" unless missing.empty?
  end

  # ---- images: lossless pixels + metadata gone ----
  def test_images_clean_losslessly_without_false_clean
    skip 'ImageMagick (convert) not installed' unless have?('convert')

    tested = []
    %w[jpg png gif bmp tiff webp].each do |ext|
      Dir.mktmpdir do |d|
        f = File.join(d, "x.#{ext}")
        next unless gen_image(f)

        tested << ext
        before = pixels(f)
        assert_clean(ext, f)
        assert_equal before, pixels(f), "#{ext}: pixels changed — clean was not lossless" if before
      end
    end
    refute_empty tested, 'no image formats could be generated (ImageMagick delegates missing?)'
  end

  # ---- audio: stream-identical + metadata gone ----
  def test_audio_clean_losslessly_without_false_clean
    tested = []
    %w[mp3 flac ogg opus wav m4a].each do |ext|
      Dir.mktmpdir do |d|
        f = File.join(d, "x.#{ext}")
        next unless gen_audio(f)

        tested << ext
        before = stream_hash(f, '0:a', 'md5')
        assert_clean(ext, f)
        assert_equal before, stream_hash(f, '0:a', 'md5'), "#{ext}: audio stream changed — not lossless" if before
      end
    end
    refute_empty tested, 'no audio formats could be generated (ffmpeg encoders missing?)'
  end

  # ---- video (incl. wmv via mat2, mkv/webm via ffmpeg): stream-identical ----
  def test_video_clean_losslessly_without_false_clean
    tested = []
    %w[mp4 mov avi mkv webm wmv].each do |ext|
      Dir.mktmpdir do |d|
        f = File.join(d, "x.#{ext}")
        next unless gen_video(f, ext)

        tested << ext
        before = stream_hash(f, '0:v', 'framemd5')
        assert_clean(ext, f)
        assert_equal before, stream_hash(f, '0:v', 'framemd5'), "#{ext}: video stream changed — not lossless" if before
      end
    end
    refute_empty tested, 'no video formats could be generated'
  end

  # ---- pdf: exiftool strips the Info dict, qpdf rebuilds ----
  def test_pdf_cleans_without_false_clean
    Dir.mktmpdir do |d|
      f = File.join(d, 'doc.pdf')
      skip 'no PDF generator (gs/convert) available or PDF coder disabled' unless gen_pdf(f)

      assert_clean('pdf', f)
    end
  end

  # ---- archives: zip + epub ----
  def test_archives_clean_without_false_clean
    skip 'zip not installed' unless have?('zip')

    Dir.mktmpdir do |d|
      zip = File.join(d, 'a.zip')
      assert gen_zip(zip), 'could not build a zip sample'
      assert_equal :cleaned, clean_status(zip), 'zip should clean'
      refute still_leaks?(zip), 'zip: a privacy tag survived a :cleaned report'

      epub = File.join(d, 'b.epub')
      if gen_epub(epub)
        assert_equal :cleaned, clean_status(epub), 'epub should clean'
        refute zip_part_has_marker?(epub, 'content.opf'),
               'epub: dc:creator marker survived a :cleaned report (false-clean)'
      end
    end
  end

  # ---- office / opendocument (needs LibreOffice; soffice-optional) ----
  def test_office_documents_clean_without_false_clean
    skip 'soffice (LibreOffice) not installed' unless have?('soffice')

    tested = []
    { 'docx' => :text, 'odt' => :text, 'xlsx' => :sheet, 'ods' => :sheet }.each do |ext, kind|
      Dir.mktmpdir do |d|
        f = gen_office(d, ext, kind)
        next unless f

        tested << ext
        # soffice embeds its own identifying metadata (Application=LibreOffice…,
        # creation date); prove it's present before and gone after.
        assert office_metadata?(f), "#{ext}: precondition — soffice metadata should be present"
        assert_equal :cleaned, clean_status(f), "#{ext} should clean"
        refute office_metadata?(f), "#{ext}: document metadata survived a :cleaned report (false-clean)"
      end
    end
    refute_empty tested, 'no office formats could be generated by soffice'
  end

  # ---- svg: must FAIL CLOSED (or clean), but NEVER leak / corrupt ----
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
        # The documented case on a mat2 build that crashes on SVG: fail closed.
        assert_equal original, File.read(f), 'a failed svg clean must leave the original untouched'
      end
    end
  end

  private

  # The shared guarantee for a format we expect to clean: it reaches :cleaned AND
  # no exiftool-readable privacy marker survives.
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

  # --- tool/generator helpers ---
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
    out = IO.popen(['convert', path, '-depth', '8', 'RGBA:-'], 'rb', err: File::NULL, &:read)
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

  # Generators return the path (truthy) on success, nil otherwise — so callers
  # can `next unless gen_…` without the method reading as a boolean predicate.
  def gen_image(path)
    return unless sh('convert', '-size', '32x32', 'gradient:red-blue', path) && made?(path)

    # EXIF Artist for the raster formats that store it, XMP-dc:Creator for the rest.
    sh('exiftool', '-q', '-overwrite_original', "-Artist=#{MARKER}", "-XMP-dc:Creator=#{MARKER}",
       "-Comment=#{MARKER}", '-GPSLatitude=59.9', '-GPSLatitudeRef=N',
       '-GPSLongitude=10.7', '-GPSLongitudeRef=E', path)
    path
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

  def gen_office(dir, ext, kind)
    src = File.join(dir, kind == :sheet ? 'src.csv' : 'src.txt')
    File.write(src, kind == :sheet ? "a,b,c\n1,2,3\n" : "Hello world document.\n")
    sh('soffice', '--headless', "-env:UserInstallation=file://#{dir}/lo",
       '--convert-to', ext, '--outdir', dir, src)
    out = File.join(dir, "src.#{ext}")
    made?(out) ? out : nil
  end

  # Does a zip-based document still carry identifying metadata (the LibreOffice
  # generator string, or a Dublin Core / OOXML property block)?
  def office_metadata?(path)
    parts = IO.popen(['unzip', '-p', path, 'docProps/core.xml', 'docProps/app.xml', 'meta.xml'],
                     'rb', err: File::NULL, &:read).to_s
    parts.match?(/LibreOffice|dcterms|meta:generation|meta:creation-date|dc:date/)
  rescue StandardError
    false
  end

  def zip_part_has_marker?(path, entry)
    out = IO.popen(['unzip', '-p', path, entry], 'rb', err: File::NULL, &:read).to_s
    out.include?(MARKER)
  rescue StandardError
    false
  end
end
