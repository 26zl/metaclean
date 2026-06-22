# frozen_string_literal: true

# Thin wrapper around the external `exiftool` binary.
#
# Open3.capture3 with multiple args bypasses the shell, so a filename like
# `cat; rm -rf /` is one argument, not a command. That's not the whole story:
# exiftool still parses its own arguments, so a filename beginning with "-"
# (e.g. `-config`) would be read as an option. Every path goes through
# `Metaclean.safe_path`, which prefixes a leading dash with "./" so it's
# always seen as a filename.

require 'open3'
require 'json'

module Metaclean
  module Exiftool
    module_function

    # True if `exiftool` is on PATH. Memoized so repeated checks don't re-spawn
    # it (defined? not nil? — the cached value can legitimately be false).
    def available?
      return @available if defined?(@available)

      out, _err, status = Open3.capture3('exiftool', '-ver')
      @available = status.success?
      # Stash the version off the same call so `version` need not re-spawn.
      @version = @available ? out.strip : nil
      @available
    rescue Errno::ENOENT
      @version = nil
      @available = false # exiftool not on PATH
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

    # ExifTool can READ many formats it cannot WRITE, and mat2 owns the strip for
    # them: the ZIP-based documents (docx/xlsx/pptx/odt/ods/odp/odg/odf/epub) and
    # the RIFF containers (avi/wav). ExifTool announces the inability with one of
    # a few phrasings — "writing of X files is not yet supported", "does not yet
    # support writing of …", or "Can't currently write RIFF … files" — so we
    # match all of them. strip! returns :unsupported in these cases so the runner
    # treats it as a soft skip (mat2 does the actual strip), NOT a pipeline
    # failure that would wrongly pin an already-clean file at :unverified. This is
    # safe because the post-strip residual re-read still gates the :cleaned status.
    WRITE_UNSUPPORTED_RE = /not yet support|can't currently write|writing of .* files/i

    # Removes every removable tag, in place. Returns true on success,
    # :unsupported when ExifTool cannot write the format, and raises on failure.
    #
    # `-all=` sets every tag to empty, which deletes them. `-overwrite_original`
    # makes ExifTool replace the file directly instead of writing `file_original`
    # next to it. `-api largefilesupport=1` lets files larger than 4 GB through.
    def strip!(path, also_delete: [])
      # `-all=` clears metadata, but for TIFF/DNG ExifTool refuses to delete the
      # IFD0 directory and leaves its tags (Artist, Software, …) behind. So we
      # ALSO delete the known privacy tags by name and clear the GPS group: both
      # are no-ops where `-all=` already removed them (e.g. JPEG), but they make
      # the strip complete AND lossless (no re-encode) for IFD0-preserving formats.
      args = ['exiftool', '-all=', '-gps:all=']
      also_delete.each { |tag| args << "-#{tag}=" }
      args.concat(['-overwrite_original', '-q', '-q', '-api', 'largefilesupport=1', Metaclean.safe_path(path)])

      _out, err, status = Open3.capture3(*args)
      return true if status.success?
      return :unsupported if err.match?(WRITE_UNSUPPORTED_RE)

      raise Error, "ExifTool strip failed: #{err.strip}"
    end
  end
end
