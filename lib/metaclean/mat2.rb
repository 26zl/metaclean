# frozen_string_literal: true

# Wrapper around the external `mat2` (Metadata Anonymisation Toolkit 2).
#
# mat2 is stricter than ExifTool on certain formats (DOCX/PDF/PNG): instead
# of blacklisting known tags, it rebuilds the file from scratch keeping only
# the bytes it understands. The trade-off is that mat2 supports fewer formats.
#
# mat2's CLI quirk: it does NOT overwrite the original. It writes a new file
# named `<name>.cleaned.<ext>` next to it. We adapt by renaming that result
# back over the source after a successful run.

require 'open3'
require 'fileutils'

module Metaclean
  module Mat2
    # File extensions we know mat2 can handle. Keep this list conservative —
    # if mat2 doesn't actually support an extension, the call will fail
    # gracefully via UNSUPPORTED_RE below, but we'd rather not even try.
    # Deliberately ABSENT: Matroska (mkv/webm) — mat2 has no parser for it; ffmpeg
    # owns those (Strategy::FFMPEG_FORMATS). QuickTime/MP4-audio (mov/m4a) — mat2
    # can't write them and ExifTool already cleans them, so listing them only
    # caused a wasted mat2 spawn that always soft-skipped. WMV (ASF) IS here on
    # purpose: mat2 CAN write it but ExifTool can't, so mat2 is the only tool that
    # cleans .wmv — dropping it would make every .wmv permanently :failed.
    SUPPORTED_EXTS = %w[
      pdf png jpg jpeg tif tiff gif bmp svg webp
      mp3 flac ogg opus wav
      mp4 avi wmv
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

      out, _err, status = Open3.capture3('mat2', '--version')
      @available = status.success?
      # `mat2 --version` prints "mat2 0.14.0" — `.split.last` grabs the
      # version number regardless of whatever prefix appears. Captured here
      # so `version` reuses it instead of re-spawning the binary.
      @version = @available ? out.strip.split.last : nil
      @available
    rescue Errno::ENOENT
      @version = nil
      @available = false
    end

    def version
      available? ? @version : nil
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
      safe    = Metaclean.safe_path(path)

      # Defensive: if a stale `<name>.cleaned.<ext>` exists from an earlier
      # crashed run, remove it so we don't accidentally use old data.
      File.delete(cleaned) if File.exist?(cleaned)

      out, err, status = Open3.capture3('mat2', safe)

      # Success path first. mat2 only creates `<name>.cleaned.<ext>` when it
      # actually stripped something; no file after exit 0 means there was
      # nothing to remove. We check exit status BEFORE the "unsupported"
      # message so a successful run that merely warns about one embedded
      # stream isn't misreported as a soft skip.
      if status.success?
        return :no_metadata unless File.exist?(cleaned)

        FileUtils.mv(cleaned, safe)
        return true
      end

      # Failure path. A "not supported" message means a soft skip we report
      # so the runner can continue with the next tool, not a hard error.
      combined = "#{out}\n#{err}"
      return :unsupported if combined.match?(UNSUPPORTED_RE)

      # `err.strip.empty? ? out.strip : err.strip` picks whichever stream
      # has actual content — some tools log to stdout, others to stderr.
      raise Error, "mat2 failed: #{err.strip.empty? ? out.strip : err.strip}"
    ensure
      # Interrupt-safety: if we were killed (Ctrl-C) between mat2 writing
      # `<name>.cleaned.<ext>` and the rename, don't leave the orphan behind.
      # On the success path it's already moved, so this is a no-op.
      File.delete(cleaned) if cleaned && File.exist?(cleaned)
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
