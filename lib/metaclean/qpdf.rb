# frozen_string_literal: true

# Wrapper around `qpdf` — a PDF structural cleaner.
#
# Why qpdf on top of mat2/ExifTool? PDFs hide metadata in places those two
# don't always reach: orphaned objects, unused image streams, old revisions.
# qpdf rebuilds the PDF using only referenced objects — a final pass after the
# other tools have stripped the obvious metadata.

require 'open3'
require 'fileutils'
require 'securerandom'

module Metaclean
  module Qpdf
    module_function

    def available?
      return @available if defined?(@available)

      out, _err, status = Open3.capture3('qpdf', '--version')
      @available = status.success?
      # `qpdf --version` prints "qpdf version 11.9.0" on its first line. We
      # keep just the bare number (`.split.last`) so callers don't each have
      # to post-process it — matching Exiftool.version / Mat2.version. Captured
      # here so `version` reuses it instead of re-spawning the binary.
      @version = @available ? out.lines.first.to_s.strip.split.last : nil
      @available
    rescue Errno::ENOENT
      @version = nil
      @available = false
    end

    def version
      available? ? @version : nil
    end

    # Rebuilds a PDF in place. The qpdf flags here:
    #   --linearize                          → optimize for streaming/web
    #   --object-streams=generate            → bundle objects efficiently
    #   --remove-unreferenced-resources=yes  → drop unused content (the
    #                                           privacy-relevant part!)
    #
    # qpdf can't write back to the same file, so we use the standard
    # "atomic write" pattern: write to a temp file, then rename it on top of
    # the original. `File.rename` (used internally by `FileUtils.mv` for
    # same-filesystem moves) is atomic on POSIX — either the swap completes
    # or nothing changes. No "half-written" state is ever visible.
    def rebuild!(path)
      raise Error, 'qpdf not available' unless available?

      src = Metaclean.safe_path(path)
      tmp = tmp_path_for(path)

      _out, err, status = Open3.capture3(
        'qpdf', '--linearize', '--object-streams=generate',
        '--remove-unreferenced-resources=yes', src, Metaclean.safe_path(tmp)
      )

      # qpdf has a quirk: exit code 3 means "succeeded with warnings" (output
      # is still produced and valid). We treat that the same as success.
      success = status.success? || status.exitstatus == 3
      raise Error, "qpdf failed: #{err.strip}" unless success && File.exist?(tmp)

      FileUtils.mv(tmp, src)
      true
    ensure
      # Interrupt-safety: drop the temp if we died (or failed) before the
      # rename. On success it's already moved, so this is a no-op.
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    # Short sibling temp in the same directory: same-fs rename, unpredictable
    # name, and no risk of exceeding filename length by appending to a long PDF.
    def tmp_path_for(path)
      File.join(File.dirname(path), "#{Metaclean::TMP_MARKER}qpdf.#{Process.pid}.#{SecureRandom.hex(8)}.pdf")
    end
  end
end
