# frozen_string_literal: true

module Metaclean
  module Strategy
    PRIVACY_GROUP_PREFIXES = %w[GPS XMP- MakerNotes IPTC IFD1].freeze

    MAT2_ESSENTIAL = %w[
      docx xlsx pptx odt ods odp odg odf odc odi epub
      zip tar torrent html htm xhtml xht ncx
    ].freeze

    PRIVACY_TAGS = %w[
      Artist Author Creator Copyright Rights
      By-line By-lineTitle Credit Source Contact OwnerName
      CameraOwnerName SerialNumber InternalSerialNumber LensSerialNumber
      CameraSerialNumber UniqueCameraModel LocalizedCameraModel
      RawDataUniqueID OriginalRawFileName OriginalRawFileData
      OriginalRawFileDigest RawImageDigest NewRawImageDigest
      CameraCalibrationSignature ProfileCalibrationSignature
      ProfileName ProfileCopyright AsShotProfileName
      Software HostComputer ProcessingSoftware
      ImageDescription UserComment
      LastModifiedBy LastSavedBy LastAuthor
      Make Model LensModel DateTimeOriginal CreateDate
      Title Subject Keywords Description Category Producer Company Manager
      CreationDate ModDate
      XPAuthor XPComment XPSubject XPKeywords XPTitle Comment
    ].freeze

    MAT2_PREFERRED = %w[
      docx xlsx pptx odt ods odp odg odf odc odi epub png svg svgz
      mp4 avi
    ].freeze

    RESIDUAL_IGNORED_GROUPS = %w[System ExifTool Composite].freeze

    ICC_PRIVACY_TAGS = %w[
      ProfileDescription ProfileDescriptionML ProfileCopyright ProfileCreator
      ProfileCMMType DeviceManufacturer DeviceModel DeviceMfgDesc DeviceModelDesc
    ].freeze

    ICC_STANDARD_DESCRIPTIONS = [
      'srgb iec61966-2.1', 'srgb', 'srgb iec61966-2-1 black scaled',
      'srgb iec61966-2-1 no black scaling', 'display p3', 'dci-p3', 'p3-d65 (display)',
      'adobe rgb (1998)', 'prophoto rgb', 'romm rgb: iso 22028-2:2013',
      'apple rgb', 'colormatch rgb', 'camera rgb profile',
      'apple wide color sharing profile', 'linear rgb profile',
      'generic rgb profile', 'generic gray profile', 'generic gray gamma 2.2 profile',
      'generic lab profile', 'generic cmyk profile', 'generic xyz profile',
      'gray gamma 2.2', 'dot gain 20%',
      'rec. itu-r bt.709-5', 'hdtv (rec. 709)', 'sdtv (rec. 601)'
    ].freeze

    FFMPEG_FORMATS = %w[mkv webm].freeze

    MAT2_DEGRADES = %w[jpg jpe jpeg webp tif tiff heic].freeze

    module_function

    def tools_for(path)
      ext = Metaclean.ext_of(path)
      tools = []

      if ext == 'pdf'
        tools << :exiftool
        tools << :qpdf if Qpdf.available?
      elsif FFMPEG_FORMATS.include?(ext)
        tools << :ffmpeg if Ffmpeg.available?
      elsif MAT2_PREFERRED.include?(ext) && Mat2.available?
        tools << :mat2
        tools << :exiftool
      else
        tools << :exiftool
        tools << :mat2 if Mat2.supports?(path) && !MAT2_DEGRADES.include?(ext)
      end

      tools
    end

    def privacy_residual(meta, allow_icc_metadata: false)
      standard_icc = standard_icc_profile?(meta)
      meta.select do |k, v|
        key = k.to_s
        next false if key == 'SourceFile'

        group, tag = key.split(':', 2)
        name = tag.nil? ? group.to_s : tag
        next false if RESIDUAL_IGNORED_GROUPS.include?(group.to_s)

        icc_privacy = group.to_s.start_with?('ICC') && ICC_PRIVACY_TAGS.include?(name)
        if group.to_s.start_with?('ICC')
          next false if allow_icc_metadata || standard_icc
          next false unless icc_privacy
        end

        gps = group.to_s.start_with?('GPS') || name.start_with?('GPS')
        next false if !gps && exempt_blank?(name, v)

        icc_privacy || privacy_group?(group) || privacy_tag?(name)
      end
    end

    def standard_icc_profile?(meta)
      meta.any? do |k, v|
        key = k.to_s
        next false unless key.start_with?('ICC') && key.split(':', 2).last == 'ProfileDescription'

        ICC_STANDARD_DESCRIPTIONS.include?(normalize_icc_value(v))
      end
    end

    def normalize_icc_value(value)
      value.to_s.strip.downcase.gsub(/\s+/, ' ')
    end

    def exempt_blank?(name, value)
      return true if value.to_s.strip.empty?

      date_like_tag?(name) && blank_value?(value)
    end

    def date_like_tag?(name)
      n = name.to_s
      n.end_with?('Date') || n.start_with?('DateTime')
    end

    def blank_value?(value)
      s = value.to_s
      s.strip.empty? || s.gsub(/[Z0\s:.+-]/, '').empty?
    end

    def privacy_group?(group)
      PRIVACY_GROUP_PREFIXES.any? { |p| group.to_s.start_with?(p) }
    end

    def privacy_tag?(tag)
      t = tag.to_s
      return true if PRIVACY_TAGS.include?(t) || t.start_with?('GPS')
      return true if t.match?(/SerialNumber\z/i)
      return true if t.match?(/\AOriginalRawFile(?:Name|Data|Digest)\z/i)
      return true if t.match?(/\A(?:RawDataUniqueID|RawImageDigest|NewRawImageDigest)\z/i)

      false
    end

    def mat2_essential?(path)
      MAT2_ESSENTIAL.include?(Metaclean.ext_of(path))
    end
  end
end
