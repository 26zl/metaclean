# frozen_string_literal: true

require_relative 'test_helper'

class StrategyTest < Minitest::Test
  S = Metaclean::Strategy

  def residual(hash = nil, **options)
    if hash.nil?
      hash = options
      options = {}
    end
    S.privacy_residual(hash, **options)
  end

  def test_gps_group_flagged
    refute_empty residual('GPS:GPSLatitude' => 59.9)
  end

  def test_gps_carried_in_xmp_flagged
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
    refute_empty residual('IFD0:Make' => 'Apple')
    refute_empty residual('IFD0:Model' => 'iPhone 15')
    refute_empty residual('ExifIFD:DateTimeOriginal' => '2026:01:01 12:00:00')
    refute_empty residual('ExifIFD:LensModel' => 'Wide camera')
  end

  def test_dng_identity_and_correlation_tags_are_flagged
    %w[
      UniqueCameraModel CameraSerialNumber RawDataUniqueID
      OriginalRawFileName OriginalRawFileDigest
    ].each do |tag|
      refute_empty residual("IFD0:#{tag}" => 'private'), tag
    end
  end

  def test_native_document_properties_flagged
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

  def test_windows_xp_tags_and_comment_flagged
    refute_empty residual('IFD0:XPAuthor' => 'Jane')
    refute_empty residual('IFD0:XPComment' => 'secret note')
    refute_empty residual('IFD0:XPKeywords' => 'confidential')
    refute_empty residual('PNG:Comment' => 'hidden')
  end

  def test_file_group_comment_is_flagged
    refute_empty residual('File:Comment' => 'secret archive comment')
  end

  def test_file_group_structural_fields_not_flagged
    assert_empty residual('File:FileModifyDate' => '2026:06:28 12:00:00+02:00')
    assert_empty residual('File:FileSize' => 12_345)
    assert_empty residual('File:MIMEType' => 'image/jpeg')
    assert_empty residual('File:FileType' => 'JPEG')
    assert_empty residual('File:ImageWidth' => 4000)
    assert_empty residual('File:ZipCRC' => '0x1a2b3c')
  end

  def test_zeroed_identity_values_are_not_treated_as_blank
    refute_empty residual('IFD0:SerialNumber' => '00000000')
    refute_empty residual('IFD0:Artist' => '0000')
    refute_empty residual('IFD0:CameraSerialNumber' => '0-0-0-0')
  end

  def test_truly_empty_value_still_exempt
    assert_empty residual('PDF:Author' => '')
    assert_empty residual('IFD0:Artist' => '   ')
  end

  def test_system_group_not_flagged
    assert_empty residual('System:FileName' => 'a.jpg')
  end

  def test_icc_profile_identity_requires_explicit_acceptance
    meta = { 'ICC_Profile:ProfileCopyright' => 'Jane Doe Studio' }
    refute_empty residual(meta)
    assert_empty residual(meta, allow_icc_metadata: true)
  end

  def test_standard_icc_color_space_does_not_block_a_clean
    meta = {
      'ICC_Profile:ProfileDescription' => 'sRGB IEC61966-2.1',
      'ICC_Profile:ProfileCopyright' => 'Copyright (c) 1998 Hewlett-Packard Company',
      'ICC-header:ProfileCreator' => 'Hewlett-Packard'
    }
    assert_empty residual(meta), 'a recognized standard color space is not identifying'
    assert_empty residual('ICC_Profile:ProfileDescription' => 'Display P3')
  end

  def test_non_standard_icc_profile_still_fails_closed
    refute_empty residual('ICC_Profile:ProfileDescription' => 'Jane Doe Studio Profile')
    refute_empty residual(
      'ICC_Profile:ProfileDescription' => 'Acme Custom',
      'ICC_Profile:ProfileCopyright' => 'Jane Doe Studio'
    )
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

  def test_zeroed_or_blank_value_not_flagged
    assert_empty residual('QuickTime:CreateDate' => '0000:00:00 00:00:00')
    assert_empty residual('PDF:Author' => '')
  end

  def test_real_value_still_flagged
    refute_empty residual('QuickTime:CreateDate' => '2026:01:01 12:00:00')
    refute_empty residual('PDF:Author' => 'Jane Doe')
  end

  def test_zeroed_or_null_gps_still_flagged
    refute_empty residual('GPS:GPSLatitude' => 0)
    refute_empty residual('GPS:GPSLongitude' => '0 0 0')
    refute_empty residual('GPS:GPSLatitude' => nil)
    refute_empty residual('XMP-exif:GPSAltitude' => 0)
  end

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

  def test_zeroed_asf_creationdate_not_flagged
    assert_empty residual('ASF:CreationDate' => '0000:00:00 00:00:00Z')
    refute_empty residual('ASF:CreationDate' => '2024:01:01 12:00:00Z')
  end

  def test_mat2_essential
    assert S.mat2_essential?('report.docx')
    assert S.mat2_essential?('/x/y.ODT'), 'should be case-insensitive'
    assert S.mat2_essential?('private.html')
    assert S.mat2_essential?('archive.tar')
    refute S.mat2_essential?('photo.jpg')
    refute S.mat2_essential?('doc.pdf'), 'PDF is handled by exiftool + qpdf, not mat2'
  end

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

  def test_degraded_rasters_are_exiftool_only
    Metaclean::Mat2.stub(:supports?, true) do
      %w[a.jpg a.jpeg a.webp a.tif a.tiff].each do |f|
        assert_equal %i[exiftool], S.tools_for(f), f
      end
    end
  end

  def test_matroska_uses_ffmpeg_only
    Metaclean::Ffmpeg.stub(:available?, true) do
      assert_equal %i[ffmpeg], S.tools_for('a.mkv')
      assert_equal %i[ffmpeg], S.tools_for('/x/y.WEBM'), 'should be case-insensitive'
    end
  end

  def test_wmv_keeps_mat2_in_pipeline
    Metaclean::Mat2.stub(:available?, true) do
      assert_includes S.tools_for('a.wmv'), :mat2
    end
  end

  def test_else_branch_adds_mat2_when_supported_and_lossless
    Metaclean::Mat2.stub(:supports?, true) do
      assert_equal %i[exiftool mat2], S.tools_for('a.mp3')
    end
  end

  def test_html_and_tar_route_through_mat2
    Metaclean::Mat2.stub(:supports?, true) do
      assert_equal %i[exiftool mat2], S.tools_for('private.html')
      assert_equal %i[exiftool mat2], S.tools_for('archive.tar')
    end
  end

  def test_else_branch_is_exiftool_only_when_mat2_cannot_help
    Metaclean::Mat2.stub(:supports?, false) do
      assert_equal %i[exiftool], S.tools_for('a.mp3')
    end
  end

  def test_every_declared_mat2_extension_is_routed_or_intentionally_exiftool_only
    excluded = %w[pdf] + S::MAT2_DEGRADES
    Metaclean::Mat2.stub(:available?, true) do
      Metaclean::Qpdf.stub(:available?, true) do
        Metaclean::Mat2::SUPPORTED_EXTS.each do |ext|
          tools = S.tools_for("sample.#{ext}")
          if excluded.include?(ext)
            refute_includes tools, :mat2, ext
          else
            assert_includes tools, :mat2, ext
          end
        end
      end
    end
  end
end
