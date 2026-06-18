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

    # Formats where ExifTool alone leaves document-internal metadata that only
    # mat2's rebuild removes (and which ExifTool also can't fully re-read to
    # verify). If mat2 won't run for one of these, the runner warns that
    # coverage is reduced rather than reporting a confident "Cleaned".
    MAT2_ESSENTIAL = %w[pdf docx xlsx pptx odt ods odp odg odf epub].freeze

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
    MAT2_PREFERRED = %w[
      pdf docx xlsx pptx odt ods odp odg odf epub png svg
      mp4 avi mkv mov webm
    ].freeze

    module_function

    # Returns an ordered list of tool symbols (e.g. `[:mat2, :exiftool, :qpdf]`)
    # to run on `path`. The runner executes them in order; if one fails or
    # is skipped, the next still runs. The three tools are always used together
    # for maximum coverage — there is no per-tool opt-out; a tool that isn't
    # installed is simply left out (the `.available?`/`.supports?` checks).
    def tools_for(path)
      ext = File.extname(path).downcase.delete('.')
      tools = []

      if ext == 'pdf'
        # PDFs benefit from all three, in this order:
        #   mat2 → cleans the high-level metadata + content streams it knows
        #   exiftool → strips the Info dictionary (Author, Title, Producer)
        #   qpdf → rebuilds the file, dropping any unreferenced bits
        tools << :mat2 if Mat2.available?
        tools << :exiftool
        tools << :qpdf if Qpdf.available?
      elsif MAT2_PREFERRED.include?(ext) && Mat2.available?
        # Office docs, modern image/video containers — mat2 leads.
        tools << :mat2
        tools << :exiftool
      else
        # Everything else (JPEG, MP3, RAW, …) — ExifTool is the gold standard.
        tools << :exiftool
        tools << :mat2 if Mat2.supports?(path)
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
      meta.select do |k, _|
        # Skip SourceFile and the System/File/etc. groups — not user metadata.
        next false unless Display.embedded_key?(k)

        # ExifTool keys look like "GPS:GPSLatitude". Split on the first ":";
        # no "Group:" prefix means the whole key is the tag name.
        group, tag = k.to_s.split(':', 2)
        name = tag.nil? ? group.to_s : tag
        privacy_group?(group) || privacy_tag?(name)
      end
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
      MAT2_ESSENTIAL.include?(File.extname(path).downcase.delete('.'))
    end
  end
end
