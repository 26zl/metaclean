# frozen_string_literal: true

# ───────────────────────────────────────────────────────────────────────────
# Wrapper around `qpdf` — a PDF structural cleaner.
#
# Why qpdf in addition to mat2/ExifTool? PDFs can carry metadata in places
# those two don't always reach: orphaned objects, unused image streams,
# old revisions kept in the file. qpdf rebuilds the PDF from scratch using
# only the objects actually referenced by the document. That's a great
# final pass after the other tools have stripped the obvious metadata.
# ───────────────────────────────────────────────────────────────────────────

require 'open3'
require 'fileutils'

module Metaclean
  module Qpdf
    module_function

    def available?
      return @available if defined?(@available)

      _out, _err, status = Open3.capture3('qpdf', '--version')
      @available = status.success?
    rescue Errno::ENOENT
      @available = false
    end

    def version
      return nil unless available?

      out, _err, status = Open3.capture3('qpdf', '--version')
      # `qpdf --version` prints multiple lines starting with the version line.
      # `.lines.first` grabs only that line.
      status.success? ? out.lines.first.to_s.strip : nil
    rescue Errno::ENOENT
      nil
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

      # Including `Process.pid` in the temp name avoids collisions if two
      # metaclean processes happen to run at the same time on shared storage.
      tmp = "#{path}.qpdf.tmp.#{Process.pid}"

      _out, err, status = Open3.capture3(
        'qpdf', '--linearize', '--object-streams=generate',
        '--remove-unreferenced-resources=yes', path.to_s, tmp
      )

      # qpdf has a quirk: exit code 3 means "succeeded with warnings" (output
      # is still produced and valid). We treat that the same as success.
      success = status.success? || status.exitstatus == 3
      unless success
        File.delete(tmp) if File.exist?(tmp)
        raise Error, "qpdf failed: #{err.strip}"
      end

      FileUtils.mv(tmp, path.to_s)
      true
    end
  end
end
