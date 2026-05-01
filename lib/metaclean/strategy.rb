# frozen_string_literal: true

# ───────────────────────────────────────────────────────────────────────────
# The "policy" module: which tools to run for which file, and what counts as
# privacy-relevant if it survives a clean.
#
# Keeping this logic in its own file means the runner doesn't need to know
# about formats — it just asks Strategy.tools_for(path) and runs whatever
# comes back.
# ───────────────────────────────────────────────────────────────────────────

module Metaclean
  module Strategy
    # Tag GROUPS that almost always carry personally identifying info.
    # Survival of any tag in these groups raises a flag to the user.
    PRIVACY_GROUPS = %w[GPS MakerNotes XMP-dc XMP-photoshop IPTC ICC-header].freeze

    # Specific tag NAMES (regardless of group) we never want to leak.
    # If exiftool reports e.g. "EXIF:Artist" we still flag it because of the
    # tag-name match, not the group.
    PRIVACY_TAGS = %w[
      Artist Author Creator Copyright Rights
      By-line By-lineTitle Credit Source Contact OwnerName
      CameraOwnerName SerialNumber InternalSerialNumber LensSerialNumber
      Software HostComputer ProcessingSoftware
      ImageDescription UserComment
      LastModifiedBy LastSavedBy LastAuthor
    ].freeze

    # File extensions where mat2 is meaningfully stricter than ExifTool and
    # should run first. For other formats, ExifTool is the broader expert.
    MAT2_PREFERRED = %w[
      pdf docx xlsx pptx odt ods odp odg epub png svg
      mp4 avi mkv mov webm
    ].freeze

    module_function

    # Returns an ordered list of tool symbols (e.g. `[:mat2, :exiftool, :qpdf]`)
    # to run on `path`. The runner executes them in order; if one fails or
    # is skipped, the next still runs.
    #
    # `prefer:` is a hash of user opt-outs from the CLI flags
    # (--no-mat2, --exiftool-only, etc.). The pattern `prefer[:mat2] != false`
    # treats both `nil` (not set) and `true` as "use it" — only an explicit
    # `false` disables.
    def tools_for(path, prefer: {})
      ext = File.extname(path).downcase.delete('.')
      tools = []

      if ext == 'pdf'
        # PDFs benefit from all three, in this order:
        #   mat2 → cleans the high-level metadata + content streams it knows
        #   exiftool → strips the Info dictionary (Author, Title, Producer)
        #   qpdf → rebuilds the file, dropping any unreferenced bits
        tools << :mat2     if prefer[:mat2]     != false && Mat2.available?
        tools << :exiftool if prefer[:exiftool] != false
        tools << :qpdf     if prefer[:qpdf]     != false && Qpdf.available?
      elsif MAT2_PREFERRED.include?(ext) && prefer[:mat2] != false && Mat2.available?
        # Office docs, modern image/video containers — mat2 leads.
        tools << :mat2
        tools << :exiftool if prefer[:exiftool] != false
      else
        # Everything else (JPEG, MP3, RAW, …) — ExifTool is the gold standard.
        tools << :exiftool if prefer[:exiftool] != false
        tools << :mat2     if prefer[:mat2]     != false && Mat2.supports?(path)
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
      meta.reject { |k, _| k == 'SourceFile' }.select do |k, _|
        # ExifTool keys look like "GPS:GPSLatitude". Split on the first ":".
        group, tag = k.to_s.split(':', 2)
        # Skip System/File/etc. — those aren't user metadata.
        next false if Display::NON_METADATA_GROUPS.include?(group)

        if tag.nil?
          # No "Group:" prefix — the whole key is the tag name.
          PRIVACY_TAGS.include?(group.to_s)
        else
          PRIVACY_GROUPS.include?(group) || PRIVACY_TAGS.include?(tag)
        end
      end
    end
  end
end
