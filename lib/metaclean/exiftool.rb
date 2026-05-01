# frozen_string_literal: true

# ───────────────────────────────────────────────────────────────────────────
# A thin Ruby wrapper around the external `exiftool` binary.
#
# We use `Open3.capture3` instead of backticks or `system()` because:
#   1. It returns stdout, stderr, and the process status separately.
#   2. When called with multiple arguments, it bypasses the shell entirely
#      — so a filename like `cat; rm -rf /` is treated as ONE filename, not
#      a shell command. This is the standard way to safely shell out in Ruby.
# ───────────────────────────────────────────────────────────────────────────

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

      _out, _err, status = Open3.capture3('exiftool', '-ver')
      @available = status.success?
    rescue Errno::ENOENT
      # `Errno::ENOENT` ("no such file or directory") is what Open3 raises
      # when the executable can't be found. We treat that as "not available".
      @available = false
    end

    # Returns the version string, or nil if exiftool is missing/broken.
    def version
      return nil unless available?

      out, _err, status = Open3.capture3('exiftool', '-ver')
      status.success? ? out.strip : nil
    rescue Errno::ENOENT
      nil
    end

    # Hard-fail with a helpful install hint. Called from `read`/`strip!` before
    # any work, so users see one clear message instead of a low-level Errno.
    # The `<<~MSG ... MSG` is a "squiggly heredoc": leading indentation is
    # stripped automatically, so the output is left-aligned.
    def ensure_available!
      return if available?

      raise ExiftoolMissing, <<~MSG
        ExifTool is not installed or not on PATH.

        Install:
          macOS:    brew install exiftool
          Debian:   sudo apt install libimage-exiftool-perl
          Fedora:   sudo dnf install perl-Image-ExifTool
          Arch:     sudo pacman -S perl-image-exiftool
          Windows:  scoop install exiftool   (or download exiftool.org)
      MSG
    end

    # Reads metadata from a file and returns a flat Hash of "Group:Tag" => value.
    #
    # ExifTool flag glossary:
    #   -j         JSON output (machine-parseable)
    #   -G1        Include the family-1 group name (e.g. "EXIF", "GPS", "IPTC")
    #   -a         Allow duplicate tags (some formats have several with same name)
    #   -u         Include unknown/unidentified tags
    #   -s         Short tag names (no descriptions)
    #   -n         Numeric values (no human formatting like "1/100 sec")
    #   -api largefilesupport=1   Allow files >4 GB
    def read(path)
      ensure_available!
      out, err, status = Open3.capture3(
        'exiftool', '-j', '-G1', '-a', '-u', '-s', '-n', '-api', 'largefilesupport=1', path.to_s
      )
      raise Error, "ExifTool read failed: #{err.strip}" unless status.success?

      # ExifTool's JSON output is an array (one entry per file). We always
      # pass one file, so we take the first element. `|| {}` handles the
      # edge case where exiftool returns an empty array.
      data = JSON.parse(out)
      data.first || {}
    rescue JSON::ParserError => e
      raise Error, "Could not parse ExifTool output: #{e.message}"
    end

    # Removes every removable tag, in place. Returns true on success.
    #
    # `-all=` is the magic incantation: it sets every tag to nothing (= empty),
    # which deletes them. `-overwrite_original` makes ExifTool replace the
    # file directly instead of writing `file_original` next to it.
    #
    # The optional `keep_*` flags are useful because:
    #   * Orientation tells viewers how to rotate phone photos. Removing it
    #     can show the picture sideways.
    #   * ICC profile tells viewers which color space the image is in.
    #     Removing it can shift colors.
    def strip!(path, keep_orientation: false, keep_color_profile: false)
      ensure_available!

      preserving = keep_orientation || keep_color_profile
      args = ['exiftool', '-all=']

      # `-tagsFromFile @` says "copy tags from the same file you're writing
      # to". That sounds redundant, but combined with `-all=` running first,
      # it means "delete everything, then re-add only the listed tags".
      if preserving
        args.concat(['-tagsFromFile', '@'])
        args << '-Orientation' if keep_orientation
        args << '-ICC_Profile' if keep_color_profile
      end
      args.concat(['-overwrite_original', '-q', '-q', '-api', 'largefilesupport=1', path.to_s])

      _out, err, status = Open3.capture3(*args)
      return true if status.success?

      # Some minimal/odd files reject the preserve-pass. Fall back to a plain
      # full strip — but only if we *were* preserving, otherwise the retry
      # would be identical to the failed attempt.
      raise Error, "ExifTool strip failed: #{err.strip}" unless preserving

      _out2, err2, status2 = Open3.capture3(
        'exiftool', '-all=', '-overwrite_original', '-q', '-q', path.to_s
      )
      return true if status2.success?

      raise Error, "ExifTool strip failed: #{err2.strip.empty? ? err.strip : err2.strip}"
    end
  end
end
