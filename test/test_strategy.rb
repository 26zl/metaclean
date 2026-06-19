# frozen_string_literal: true

require_relative 'test_helper'

# The privacy-critical policy module: which tools run, and what counts as a
# privacy residual. privacy_residual is THE false-clean gate, so it gets the
# most coverage.
class StrategyTest < Minitest::Test
  S = Metaclean::Strategy

  def residual(hash)
    S.privacy_residual(hash)
  end

  # privacy_residual: things that MUST be flagged (fail-closed)
  def test_gps_group_flagged
    refute_empty residual('GPS:GPSLatitude' => 59.9)
  end

  def test_gps_carried_in_xmp_flagged
    # group XMP-exif (prefix) and tag GPSLongitude (GPS*) — the exact hole the
    # old exact-allowlist missed.
    refute_empty residual('XMP-exif:GPSLongitude' => 10.7)
  end

  def test_embedded_thumbnail_flagged
    refute_empty residual('IFD1:ThumbnailImage' => '(binary 4 kB)')
  end

  def test_face_region_person_name_flagged
    refute_empty residual('XMP-mwg-rs:RegionPersonDisplayName' => 'Bob')
  end

  def test_named_tag_flagged_regardless_of_group
    refute_empty residual('IFD0:Artist' => 'Jane')
  end

  def test_device_and_capture_fingerprint_flagged
    # Device fingerprint + capture timestamp survivors are a privacy leak; the
    # backstop must flag them even though they live under benign IFD0/ExifIFD.
    refute_empty residual('IFD0:Make' => 'Apple')
    refute_empty residual('IFD0:Model' => 'iPhone 15')
    refute_empty residual('ExifIFD:DateTimeOriginal' => '2026:01:01 12:00:00')
    refute_empty residual('ExifIFD:LensModel' => 'Wide camera')
  end

  def test_native_document_properties_flagged
    # OOXML core/app props (group "XML") and PDF Info-dict entries (group "PDF")
    # are NOT under an XMP- prefix, so without these names a doc cleaned by
    # ExifTool alone (no mat2) could leak title/author-org/keywords unflagged.
    refute_empty residual('XML:Title' => 'Q3 Layoff Plan')
    refute_empty residual('XML:Company' => 'ACME Corp')
    refute_empty residual('XML:Manager' => 'Jane CEO')
    refute_empty residual('XML:Keywords' => 'confidential')
    refute_empty residual('PDF:Subject' => 'merger')
    refute_empty residual('PDF:Producer' => 'LibreOffice 7')
    refute_empty residual('PDF:CreationDate' => '2026:01:01 00:00:00')
  end

  def test_bare_key_treated_as_tag_name
    refute_empty residual('Artist' => 'Jane')
  end

  # Windows-specific EXIF PII (XP* under group IFD0) and a bare Comment carry the
  # same author/keyword/comment data as their base tags, so the backstop flags them.
  def test_windows_xp_tags_and_comment_flagged
    refute_empty residual('IFD0:XPAuthor' => 'Jane')
    refute_empty residual('IFD0:XPComment' => 'secret note')
    refute_empty residual('IFD0:XPKeywords' => 'confidential')
    refute_empty residual('PNG:Comment' => 'hidden')
  end

  # privacy_residual: things that must NOT be flagged
  def test_system_group_not_flagged
    assert_empty residual('System:FileName' => 'a.jpg')
  end

  def test_sourcefile_not_flagged
    assert_empty residual('SourceFile' => '/x/a.jpg')
  end

  def test_benign_dimension_tag_not_flagged
    assert_empty residual('IFD0:ImageWidth' => 4000)
  end

  def test_clean_hash_returns_empty
    assert_empty residual({})
  end

  # A zeroed/empty value is not a leak — un-removable container atoms (e.g.
  # QuickTime:CreateDate, which can only be zeroed) must not block an otherwise
  # clean file, or no video could ever pass the clean gate.
  def test_zeroed_or_blank_value_not_flagged
    assert_empty residual('QuickTime:CreateDate' => '0000:00:00 00:00:00')
    assert_empty residual('PDF:Author' => '')
  end

  # …but a REAL date/value under the same tag name IS still flagged.
  def test_real_value_still_flagged
    refute_empty residual('QuickTime:CreateDate' => '2026:01:01 12:00:00')
    refute_empty residual('PDF:Author' => 'Jane Doe')
  end

  # A zeroed/null GPS coordinate is Null Island — a REAL location — so it must
  # stay flagged even though it survives blank_value?. (Regression: the blank
  # shortcut used to run BEFORE the GPS match and silently dropped it = a leak.)
  def test_zeroed_or_null_gps_still_flagged
    refute_empty residual('GPS:GPSLatitude' => 0)
    refute_empty residual('GPS:GPSLongitude' => '0 0 0')
    refute_empty residual('GPS:GPSLatitude' => nil)
    refute_empty residual('XMP-exif:GPSAltitude' => 0)
  end

  # blank_value? boundary — pinned directly so a future regex tweak can't quietly
  # widen "blank" and drop a real value past the backstop.
  def test_blank_value_boundary
    assert S.blank_value?('')
    assert S.blank_value?(nil)
    assert S.blank_value?('0000:00:00 00:00:00')
    assert S.blank_value?('0000:00:00 00:00:00Z'), 'ASF (WMV) zeroed UTC date is blank'
    assert S.blank_value?('0.0')
    refute S.blank_value?('1')
    refute S.blank_value?('N')
    refute S.blank_value?('59.9139')
    refute S.blank_value?('2024:01:01 12:00:00Z'), 'a REAL UTC date is not blank'
    refute S.blank_value?('Zoe'), 'only the digit 0 and Z are stripped, not letters'
  end

  # WMV (ASF): mat2 strips Title/Author but writes a zeroed mandatory date
  # "0000:00:00 00:00:00Z". That date must be treated as blank (not a leak), or
  # every cleaned WMV would wrongly report :failed even though it is clean.
  def test_zeroed_asf_creationdate_not_flagged
    assert_empty residual('ASF:CreationDate' => '0000:00:00 00:00:00Z')
    refute_empty residual('ASF:CreationDate' => '2024:01:01 12:00:00Z') # a real one is flagged
  end

  # mat2_essential?
  def test_mat2_essential
    assert S.mat2_essential?('report.docx')
    assert S.mat2_essential?('/x/y.ODT'), 'should be case-insensitive'
    refute S.mat2_essential?('photo.jpg')
    refute S.mat2_essential?('doc.pdf'), 'PDF is handled by exiftool + qpdf, not mat2'
  end

  # tools_for: pipeline membership + ordering (binaries stubbed)
  # PDF skips mat2 (it rasterizes) — exiftool strips metadata, qpdf rebuilds.
  def test_pdf_uses_exiftool_and_qpdf_not_mat2
    Metaclean::Mat2.stub(:available?, true) do
      Metaclean::Qpdf.stub(:available?, true) do
        assert_equal %i[exiftool qpdf], S.tools_for('a.pdf')
      end
    end
  end

  def test_docx_lets_mat2_lead
    Metaclean::Mat2.stub(:available?, true) do
      assert_equal %i[mat2 exiftool], S.tools_for('a.docx')
    end
  end

  # Rasters mat2 would damage (recompress JPEG/WebP, downconvert TIFF) are
  # ExifTool-ONLY — ExifTool strips them completely in place, so mat2 is skipped
  # even when it "supports" the format.
  def test_degraded_rasters_are_exiftool_only
    Metaclean::Mat2.stub(:supports?, true) do
      %w[a.jpg a.jpeg a.webp a.tif a.tiff].each do |f|
        assert_equal %i[exiftool], S.tools_for(f), f
      end
    end
  end

  # Matroska (mkv/webm) can't be written by ExifTool (read-only) or mat2 (no
  # parser), so ffmpeg is the ONLY tool routed for them.
  def test_matroska_uses_ffmpeg_only
    Metaclean::Ffmpeg.stub(:available?, true) do
      assert_equal %i[ffmpeg], S.tools_for('a.mkv')
      assert_equal %i[ffmpeg], S.tools_for('/x/y.WEBM'), 'should be case-insensitive'
    end
  end

  # WMV (ASF) is the one container ExifTool can't write but mat2 CAN — so mat2
  # MUST stay in the pipeline (it's the only tool that strips .wmv). Regression
  # guard: dropping wmv from Mat2::SUPPORTED_EXTS makes every .wmv permanently
  # :failed.
  def test_wmv_keeps_mat2_in_pipeline
    Metaclean::Mat2.stub(:available?, true) do
      assert_includes S.tools_for('a.wmv'), :mat2
    end
  end

  # A non-lossy else-branch format mat2 supports still gets exiftool → mat2.
  def test_else_branch_adds_mat2_when_supported_and_lossless
    Metaclean::Mat2.stub(:supports?, true) do
      assert_equal %i[exiftool mat2], S.tools_for('a.mp3')
    end
  end

  def test_else_branch_is_exiftool_only_when_mat2_cannot_help
    Metaclean::Mat2.stub(:supports?, false) do
      assert_equal %i[exiftool], S.tools_for('a.mp3')
    end
  end
end
