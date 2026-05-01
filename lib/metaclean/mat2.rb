# frozen_string_literal: true

# ───────────────────────────────────────────────────────────────────────────
# Wrapper around the external `mat2` (Metadata Anonymisation Toolkit 2).
#
# mat2 is stricter than ExifTool on certain formats (DOCX/PDF/PNG): instead
# of blacklisting known tags, it rebuilds the file from scratch keeping only
# the bytes it understands. The trade-off is that mat2 supports fewer formats.
#
# mat2's CLI quirk: it does NOT overwrite the original. It writes a new file
# named `<name>.cleaned.<ext>` next to it. We adapt by renaming that result
# back over the source after a successful run.
# ───────────────────────────────────────────────────────────────────────────

require 'open3'
require 'fileutils'

module Metaclean
  module Mat2
    # File extensions we know mat2 can handle. Keep this list conservative —
    # if mat2 doesn't actually support an extension, the call will fail
    # gracefully via UNSUPPORTED_RE below, but we'd rather not even try.
    SUPPORTED_EXTS = %w[
      pdf png jpg jpeg tif tiff gif bmp svg webp
      mp3 flac ogg opus wav m4a
      mp4 avi mkv mov wmv webm
      docx xlsx pptx odt ods odp odg odf epub
      zip torrent
    ].freeze

    # Regex matching the messages mat2 prints when it can't handle a file.
    # We use this to distinguish "soft skip" from a real error.
    # `i` flag = case-insensitive.
    UNSUPPORTED_RE = /(not supported|isn't supported|cannot be cleaned|unsupported file)/i.freeze

    module_function

    # Memoized PATH check (same pattern as Exiftool.available?).
    def available?
      return @available if defined?(@available)

      _out, _err, status = Open3.capture3('mat2', '--version')
      @available = status.success?
    rescue Errno::ENOENT
      @available = false
    end

    def version
      return nil unless available?

      out, _err, status = Open3.capture3('mat2', '--version')
      # `mat2 --version` prints "mat2 0.14.0" — `.split.last` grabs the
      # version number regardless of whatever prefix appears.
      status.success? ? out.strip.split.last : nil
    rescue Errno::ENOENT
      nil
    end

    # Quick check before we even try mat2 on a file. Used by Strategy to
    # decide whether to add :mat2 to the pipeline.
    def supports?(path)
      return false unless available?

      SUPPORTED_EXTS.include?(File.extname(path).downcase.delete('.'))
    end

    # Strips metadata from `path` in place. Returns:
    #   true           — stripped successfully
    #   :no_metadata   — mat2 ran but found nothing to strip
    #   :unsupported   — mat2 cannot handle this file type
    # Raises Metaclean::Error on hard failure.
    #
    # We return symbols (instead of always raising) so the runner can show a
    # friendly "skipped" message and continue with the next tool.
    def strip!(path)
      raise Error, 'mat2 not available' unless available?

      cleaned = cleaned_path_for(path)

      # Defensive: if a stale `<name>.cleaned.<ext>` exists from an earlier
      # crashed run, remove it so we don't accidentally use old data.
      File.delete(cleaned) if File.exist?(cleaned)

      out, err, status = Open3.capture3('mat2', path.to_s)
      combined = "#{out}\n#{err}"

      # Soft skip — mat2 itself told us it can't process this file.
      # Defensive: if mat2 still wrote a partial `<name>.cleaned.<ext>`,
      # remove it so a later run doesn't pick up stale output.
      if combined.match?(UNSUPPORTED_RE)
        File.delete(cleaned) if File.exist?(cleaned)
        return :unsupported
      end

      unless status.success?
        File.delete(cleaned) if File.exist?(cleaned)
        # `err.strip.empty? ? out.strip : err.strip` picks whichever stream
        # has actual content — some tools log to stdout, others to stderr.
        raise Error, "mat2 failed: #{err.strip.empty? ? out.strip : err.strip}"
      end

      # mat2 only creates `<name>.cleaned.<ext>` when it actually stripped
      # something. If the file didn't exist after a successful run, there
      # was nothing to remove.
      if File.exist?(cleaned)
        FileUtils.mv(cleaned, path.to_s)
        true
      else
        :no_metadata
      end
    end

    # Builds the path mat2 will write to: `name.cleaned.ext`.
    # We use File.dirname/basename/join instead of string concatenation so
    # this works on Windows (\ separator) too.
    def cleaned_path_for(path)
      dir  = File.dirname(path)
      ext  = File.extname(path)
      stem = File.basename(path, ext)
      File.join(dir, "#{stem}.cleaned#{ext}")
    end
  end
end
