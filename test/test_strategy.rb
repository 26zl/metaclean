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

  # mat2_essential?
  def test_mat2_essential
    assert S.mat2_essential?('report.docx')
    assert S.mat2_essential?('/x/y.PDF'), 'should be case-insensitive'
    refute S.mat2_essential?('photo.jpg')
  end

  # tools_for: pipeline membership + ordering (binaries stubbed)
  def test_pdf_uses_all_three_in_order
    Metaclean::Mat2.stub(:available?, true) do
      Metaclean::Qpdf.stub(:available?, true) do
        assert_equal %i[mat2 exiftool qpdf], S.tools_for('a.pdf')
      end
    end
  end

  def test_docx_lets_mat2_lead
    Metaclean::Mat2.stub(:available?, true) do
      assert_equal %i[mat2 exiftool], S.tools_for('a.docx')
    end
  end

  def test_jpeg_is_exiftool_then_mat2_when_supported
    Metaclean::Mat2.stub(:supports?, true) do
      assert_equal %i[exiftool mat2], S.tools_for('a.jpg')
    end
  end

  def test_jpeg_is_exiftool_only_when_mat2_cannot_help
    Metaclean::Mat2.stub(:supports?, false) do
      assert_equal %i[exiftool], S.tools_for('a.jpg')
    end
  end
end
