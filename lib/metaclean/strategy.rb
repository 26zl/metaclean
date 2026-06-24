# frozen_string_literal: true

# The "policy" module: which tools to run for which file, and what counts as
# privacy-relevant if it survives a clean.
#
# Keeping this logic in its own file means the runner doesn't need to know
# about formats — it just asks Strategy.tools_for(path) and runs whatever
# comes back.

module Metaclean
  module Strategy
    # Group-name PREFIXES treated as privacy-bearing. Matching whole families by
    # prefix keeps the residual check fail-closed instead of an exact allowlist
    # that silently misses variants:
    #   GPS*       — GPS plus any sub-group
    #   XMP-*      — every XMP namespace (XMP-exif GPS, XMP-mwg-rs face/person
    #                names, XMP-xmpMM DocumentID, XMP-iptcExt, …)
    #   MakerNotes*, IPTC*
    #   IFD1       — the embedded thumbnail IFD; a surviving thumbnail can carry
    #                the original's full EXIF+GPS
    # Over-flagging here is deliberate: for a privacy tool a false "still
    # present" is far cheaper than a false "Cleaned". (ICC colour-profile groups
    # are intentionally NOT flagged — a colour profile isn't PII; any genuinely
    # identifying field such as Copyright is still caught by PRIVACY_TAGS below.)
    PRIVACY_GROUP_PREFIXES = %w[GPS XMP- MakerNotes IPTC IFD1].freeze

    # Formats ExifTool can't WRITE, so it leaves document-internal metadata only
    # mat2's rebuild removes (and can't re-read to verify). If mat2 won't run for
    # one of these, the runner warns coverage is reduced rather than reporting a
    # confident "Cleaned". (PDF is NOT here: ExifTool writes PDF metadata and qpdf
    # rebuilds the file, so PDF is fully handled and verifiable without mat2.)
    MAT2_ESSENTIAL = %w[docx xlsx pptx odt ods odp odg odf epub].freeze

    # Specific tag NAMES (regardless of group) we never want to leak.
    # If exiftool reports e.g. "EXIF:Artist" we still flag it because of the
    # tag-name match, not the group. exiftool's `-all=` normally strips these,
    # so this list is a fail-closed BACKSTOP: if any survive a strip we'd rather
    # over-warn than report a confident "Cleaned".
    PRIVACY_TAGS = %w[
      Artist Author Creator Copyright Rights
      By-line By-lineTitle Credit Source Contact OwnerName
      CameraOwnerName SerialNumber InternalSerialNumber LensSerialNumber
      Software HostComputer ProcessingSoftware
      ImageDescription UserComment
      LastModifiedBy LastSavedBy LastAuthor
      Make Model LensModel DateTimeOriginal CreateDate
      Title Subject Keywords Description Category Producer Company Manager
      CreationDate ModDate
      XPAuthor XPComment XPSubject XPKeywords XPTitle Comment
    ].freeze

    # File extensions where mat2 is meaningfully stricter than ExifTool and
    # should run first. For other formats, ExifTool is the broader expert.
    # (mkv/webm are NOT here — see FFMPEG_FORMATS; no mat2/ExifTool path writes
    # Matroska.)
    MAT2_PREFERRED = %w[
      docx xlsx pptx odt ods odp odg odf epub png svg
      mp4 avi
    ].freeze

    # Matroska containers. ExifTool is read-only for them and mat2 has no
    # Matroska parser, so neither can strip mkv/webm. ffmpeg is the only tool in
    # the set that can — it remuxes the container dropping all metadata while
    # copying every stream verbatim (lossless, no re-encode).
    FFMPEG_FORMATS = %w[mkv webm].freeze

    # Raster formats mat2 cannot strip without DAMAGING the file: it rebuilds via
    # Pillow, which recompresses JPEG/WebP (visible quality loss — a clean
    # wallpaper drops ~65% in size with no metadata to remove) and downconverts
    # TIFF (16-bit → 8-bit). ExifTool strips all of these completely and IN PLACE
    # (pixels byte-identical), so ExifTool owns them and mat2 is skipped —
    # cleaning metadata must never silently damage the file.
    MAT2_DEGRADES = %w[jpg jpeg webp tif tiff].freeze

    module_function

    # Returns an ordered list of tool symbols (e.g. `[:mat2, :exiftool, :qpdf]`)
    # to run on `path`. The runner executes them in order; if one fails or
    # is skipped, the next still runs. The three tools are always used together
    # for maximum coverage — there is no per-tool opt-out; a tool that isn't
    # installed is simply left out (the `.available?`/`.supports?` checks).
    def tools_for(path)
      ext = Metaclean.ext_of(path)
      tools = []

      if ext == 'pdf'
        # mat2 cleans PDFs by RASTERIZING every page (text → images): it destroys
        # the text layer and balloons the file (~35×). So PDFs skip mat2 and use:
        #   exiftool → strips the Info dictionary + XMP (Author, Title, Producer…)
        #   qpdf → rebuilds the file, dropping unreferenced objects / old revisions
        # Both are lossless and leave the text intact. (PDF JS/macros are out of
        # scope — see README.)
        tools << :exiftool
        tools << :qpdf if Qpdf.available?
      elsif FFMPEG_FORMATS.include?(ext)
        # Matroska (mkv/webm): ffmpeg is the ONLY tool that can clean these.
        # ExifTool still re-reads the result afterwards, so the residual check
        # (the false-clean backstop) is not blind.
        tools << :ffmpeg if Ffmpeg.available?
      elsif MAT2_PREFERRED.include?(ext) && Mat2.available?
        # Office docs, modern image/video containers — mat2 leads.
        tools << :mat2
        tools << :exiftool
      else
        # Everything else (JPEG, MP3, RAW, …) — ExifTool has the broadest coverage.
        # mat2 still adds coverage for many, but NOT for rasters it would damage
        # (MAT2_DEGRADES) — there ExifTool's in-place strip is complete and lossless.
        tools << :exiftool
        tools << :mat2 if Mat2.supports?(path) && !MAT2_DEGRADES.include?(ext)
      end

      tools
    end

    # Looks at metadata read AFTER cleaning and returns the entries that
    # still look privacy-relevant. The runner uses this for the "still
    # present" warning at the end of each file.
    #
    # Why both group-match and tag-match? Tag names can appear under
    # different groups depending on the format (e.g. "Author" in PDF vs
    # "Artist" in EXIF). Combining the two keeps coverage broad without
    # having to enumerate every {group, tag} pair.
    def privacy_residual(meta)
      meta.select do |k, v|
        # Skip SourceFile and the System/File/etc. groups — not user metadata.
        next false unless Display.embedded_key?(k)

        # ExifTool keys look like "GPS:GPSLatitude". Split on the first ":";
        # no "Group:" prefix means the whole key is the tag name.
        group, tag = k.to_s.split(':', 2)
        name = tag.nil? ? group.to_s : tag

        # A zeroed/empty value is not a leak for un-removable container atoms like
        # QuickTime:CreateDate (deletable only by zeroing, "0000:00:00 …") — without
        # this every video would fail the gate on an already-zeroed date. GPS is the
        # exception: 0,0 is a REAL location (Null Island) and a coordinate ExifTool
        # reports as 0 (or null) must still be caught, so the blank exemption NEVER
        # applies to GPS-family entries — the whole point of the fail-closed backstop.
        gps = group.to_s.start_with?('GPS') || name.start_with?('GPS')
        next false if !gps && blank_value?(v)

        privacy_group?(group) || privacy_tag?(name)
      end
    end

    # True when a value carries no information: empty, or only zeros plus date/time
    # punctuation and the "Z" (UTC) marker — e.g. "0000:00:00 00:00:00", or the ASF
    # variant "0000:00:00 00:00:00Z" that mat2 writes into WMV's mandatory date
    # field. Only the digit 0 is stripped (never 1-9), so a real value like
    # "59.9139", "Jane Doe", or a real "2024:..." date keeps other characters and
    # is NOT blank. (GPS is exempt from this check entirely — see privacy_residual.)
    def blank_value?(value)
      s = value.to_s
      s.strip.empty? || s.gsub(/[Z0\s:.+-]/, '').empty?
    end

    # A group is privacy-bearing if it matches one of the family prefixes
    # (GPS, XMP-, MakerNotes, IPTC, IFD1).
    def privacy_group?(group)
      PRIVACY_GROUP_PREFIXES.any? { |p| group.to_s.start_with?(p) }
    end

    # A tag is privacy-bearing if it's in the exact list OR is any GPS* tag
    # (GPSLatitude/GPSLongitude/GPSPosition/… regardless of group).
    def privacy_tag?(tag)
      t = tag.to_s
      PRIVACY_TAGS.include?(t) || t.start_with?('GPS')
    end

    # Does this path need mat2 for adequate coverage? (See MAT2_ESSENTIAL.)
    def mat2_essential?(path)
      MAT2_ESSENTIAL.include?(Metaclean.ext_of(path))
    end
  end
end
