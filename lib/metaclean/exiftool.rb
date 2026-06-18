# frozen_string_literal: true

# A thin Ruby wrapper around the external `exiftool` binary.
#
# We use `Open3.capture3` instead of backticks or `system()` because:
#   1. It returns stdout, stderr, and the process status separately.
#   2. When called with multiple arguments, it bypasses the SHELL entirely
#      — so a filename like `cat; rm -rf /` is treated as ONE argument, not
#      a shell command. This is the standard way to safely shell out in Ruby.
#
# Bypassing the shell is NOT the whole story: exiftool still parses its own
# arguments, so a filename that begins with "-" (e.g. `-config`) would be read
# as an option. We route every path through `Metaclean.safe_path` so a leading
# dash becomes "./-…" and is always seen as a filename.

require 'open3'
require 'json'

module Metaclean
  # `module Exiftool` (vs `class`) because we want module-level methods like
  # `Exiftool.read(path)` — there's no state to carry per instance.
  module Exiftool
    # `module_function` makes every method below act like a "static" method
    # on the module *and* a private instance method (rarely used). It saves
    # writing `def self.read` for every method.
    module_function

    # Returns true if `exiftool` is on PATH. The result is memoized in `@available`
    # so repeated checks don't re-spawn the process.
    #
    # `defined?(@available)` is safer than `@available.nil?` because the
    # cached value could legitimately be `false` — we want to skip the
    # re-check in that case too.
    def available?
      return @available if defined?(@available)

      out, _err, status = Open3.capture3('exiftool', '-ver')
      @available = status.success?
      # Stash the version off the same call so `version` need not re-spawn.
      @version = @available ? out.strip : nil
      @available
    rescue Errno::ENOENT
      # `Errno::ENOENT` ("no such file or directory") is what Open3 raises
      # when the executable can't be found. We treat that as "not available".
      @version = nil
      @available = false
    end

    # Returns the version string, or nil if exiftool is missing/broken.
    # Captured by `available?`, so this never re-runs the binary.
    def version
      available? ? @version : nil
    end

    # Reads metadata from a file and returns a flat Hash of "Group:Tag" => value.
    #
    # ExifTool flag glossary:
    #   -j         JSON output (machine-parseable)
    #   -G1        Include the family-1 group name. NB: with -G1 mainstream EXIF
    #              tags appear under "IFD0"/"ExifIFD"/"IFD1", not "EXIF" (that's
    #              the family-0 name); GPS/IPTC/XMP-dc keep those group names.
    #   -a         Allow duplicate tags (some formats have several with same name)
    #   -u         Include unknown/unidentified tags
    #   -s         Short tag names (no descriptions)
    #   -n         Numeric values (no human formatting like "1/100 sec")
    #   -api largefilesupport=1   Allow files >4 GB
    def read(path)
      out, err, status = Open3.capture3(
        'exiftool', '-j', '-G1', '-a', '-u', '-s', '-n', '-api', 'largefilesupport=1',
        Metaclean.safe_path(path)
      )
      raise Error, "ExifTool read failed: #{err.strip}" unless status.success?

      # ExifTool's JSON output is an array (one entry per file). We always
      # pass one file, so we take the first element. `|| {}` handles the
      # edge case where exiftool returns an empty array. A non-array shape is
      # unexpected — bail with a clear error instead of crashing later on
      # `.first` returning a Hash/scalar.
      data = JSON.parse(out)
      raise Error, 'Unexpected ExifTool output (expected a JSON array)' unless data.is_a?(Array)

      scrub_encoding(data.first || {})
    rescue JSON::ParserError => e
      raise Error, "Could not parse ExifTool output: #{e.message}"
    end

    # ExifTool labels its -j output UTF-8, but binary/odd tag values (UserComment,
    # MakerNotes fragments, corrupt or hostile files) can carry invalid bytes. A
    # later gsub (Display.format_value) raises on an invalid-encoding String and
    # would crash the whole run, so replace bad bytes up front. This hash is only
    # used for display/diff/residual checks — the actual strip operates on the
    # file via the tools — so scrubbing is safe.
    def scrub_encoding(obj)
      case obj
      when String then obj.valid_encoding? ? obj : obj.scrub
      when Array  then obj.map { |e| scrub_encoding(e) }
      when Hash   then obj.transform_values { |v| scrub_encoding(v) }
      else obj
      end
    end

    # ExifTool can READ many formats it cannot WRITE — the ZIP-based documents
    # (docx/xlsx/pptx/odt/ods/odp/odg/odf/epub) are read-only, and mat2 owns the
    # strip for them. ExifTool reports this as "...writing of X files is not yet
    # supported". strip! returns :unsupported for that case so the runner treats
    # it as a soft skip, not a pipeline failure, when mat2 already cleaned.
    WRITE_UNSUPPORTED_RE = /not yet supported|writing of .* files/i

    # Removes every removable tag, in place. Returns true on success,
    # :unsupported when ExifTool cannot write the format, and raises on failure.
    #
    # `-all=` is the magic incantation: it sets every tag to nothing (= empty),
    # which deletes them. `-overwrite_original` makes ExifTool replace the file
    # directly instead of writing `file_original` next to it. `-api
    # largefilesupport=1` lets files larger than 4 GB through.
    def strip!(path)
      _out, err, status = Open3.capture3(
        'exiftool', '-all=', '-overwrite_original', '-q', '-q', '-api', 'largefilesupport=1', Metaclean.safe_path(path)
      )
      return true if status.success?
      return :unsupported if err.match?(WRITE_UNSUPPORTED_RE)

      raise Error, "ExifTool strip failed: #{err.strip}"
    end
  end
end
