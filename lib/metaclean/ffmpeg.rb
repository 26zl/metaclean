# frozen_string_literal: true

# Wrapper around the external `ffmpeg` binary.
#
# ffmpeg is used for ONE job the other tools can't do: the Matroska containers
# (mkv/webm). ExifTool is read-only for Matroska, and mat2 has no Matroska
# parser, so without ffmpeg those formats can't be cleaned at all. ffmpeg
# rewrites the container while copying every stream verbatim (`-c copy`) — no
# re-encode, so the audio/video is bit-identical and only the metadata is gone.
#
# Like mat2, ffmpeg can't edit in place: it muxes to a new file. We write to a
# SecureRandom-named sibling and move it back over the source on success.

require 'open3'
require 'fileutils'
require 'securerandom'

module Metaclean
  module Ffmpeg
    module_function

    # Memoized PATH check (same pattern as the other wrappers).
    def available?
      return @available if defined?(@available)

      out, _err, status = Open3.capture3('ffmpeg', '-version')
      @available = status.success?
      # First line is "ffmpeg version 7.1.1 Copyright ..."; grab the 3rd token.
      @version = @available ? out.lines.first.to_s.split[2] : nil
      @available
    rescue Errno::ENOENT
      @version = nil
      @available = false
    end

    def version
      available? ? @version : nil
    end

    # Strips all metadata from `path` in place, losslessly. Returns true on
    # success, raises Metaclean::Error on failure.
    #
    #   -map 0            keep every stream (video, audio, subtitles)
    #   -map_metadata -1  drop global/container metadata
    #   -map_chapters -1  drop chapter markers (they can carry titles)
    #   -c copy           remux without re-encoding — bit-identical streams
    def strip!(path)
      raise Error, 'ffmpeg not available' unless available?

      tmp  = tmp_path_for(path)
      # Clear any stale temp from an earlier crashed run before muxing.
      File.delete(tmp) if File.exist?(tmp)

      _out, err, status = Open3.capture3(
        'ffmpeg', '-y', '-v', 'error', '-nostdin', '-i', file_url(path),
        '-map', '0', '-map_metadata', '-1', '-map_chapters', '-1', '-c', 'copy',
        file_url(tmp)
      )
      # ffmpeg can exit 0 yet write nothing on some odd inputs, so require the
      # output to actually exist before we trust it and move it into place.
      raise Error, "ffmpeg failed: #{err.strip}" unless status.success? && File.exist?(tmp)

      FileUtils.mv(tmp, path)
      true
    ensure
      # Interrupt-safety: drop the temp if we were killed between mux and rename.
      # On the success path it's already moved, so this is a no-op.
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    # Sibling temp with the SAME extension (ffmpeg picks the muxer from it) in
    # the SAME directory (so the final rename is an atomic same-fs move). The
    # ".metaclean.tmp." marker means Runner#skip? ignores any stray leftover.
    def tmp_path_for(path)
      dir  = File.dirname(path)
      ext  = File.extname(path)
      File.join(dir, ".metaclean.tmp.ff.#{Process.pid}.#{SecureRandom.hex(8)}#{ext}")
    end

    def file_url(path)
      "file:#{File.expand_path(path)}"
    end
  end
end
