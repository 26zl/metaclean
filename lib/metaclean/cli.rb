# frozen_string_literal: true

# ───────────────────────────────────────────────────────────────────────────
# Command-line argument parser.
#
# We use Ruby's standard library `OptionParser` instead of a gem like Thor
# because it has zero dependencies and is plenty for our needs. The pattern is:
#
#   1. Define each flag inside an `OptionParser.new do |o| ... end` block.
#   2. `o.on(...)` takes the flag spec and a block that runs when the flag
#      is seen. The block usually mutates `@options` to record the choice.
#   3. `parser.parse!(@argv)` consumes flags from `@argv` and leaves
#      positional args (the file paths) behind.
# ───────────────────────────────────────────────────────────────────────────

require 'optparse'

module Metaclean
  class CLI
    # Class-level convenience: `Metaclean::CLI.start(ARGV)` reads cleaner
    # than `Metaclean::CLI.new(ARGV).run`.
    def self.start(argv)
      new(argv).run
    end

    def initialize(argv)
      # `dup` makes a shallow copy so we can mutate `@argv` without
      # surprising the caller (ARGV itself stays intact).
      @argv = argv.dup

      # All options default to safe/off values. `parse!` flips them
      # selectively as it sees flags.
      @options = {
        recursive:          false,
        in_place:           false,
        no_backup:          false,
        force:              false,
        inspect_only:       false,
        format:             :pretty,
        keep_orientation:   false,
        keep_color_profile: false,
        dry_run:            false,
        follow_symlinks:    false,
        strict_verify:      false,
        no_mat2:            false,
        no_qpdf:            false,
        no_exiftool:        false,
        exiftool_only:      false,
        types:              nil
      }
      @paths = []
    end

    # Top-level dispatcher. Catches our errors and exits with codes that
    # shells/CI can act on:
    #   0  → success
    #   1  → general failure
    #   2  → ExifTool missing (specific install hint shown)
    #   130→ user pressed Ctrl-C (matches the standard SIGINT exit code)
    def run
      parse!
      runner = Runner.new(@options)
      if @options[:inspect_only]
        runner.inspect_paths(@paths)
      else
        runner.clean_paths(@paths)
      end
    rescue ExiftoolMissing => e
      warn Display.error('ExifTool missing')
      warn e.message
      exit 2
    rescue Error => e
      warn Display.error(e.message)
      exit 1
    rescue Interrupt
      # Pressing Ctrl-C raises `Interrupt`. Catching it lets us print a
      # clean message instead of a Ruby stack trace.
      warn "\n#{Display.error('Interrupted.')}"
      exit 130
    end

    private

    def parse!
      parser = OptionParser.new do |o|
        # The banner shows up at the top of `--help`.
        o.banner = 'Usage: metaclean [options] <path> [<path>...]'
        o.separator ''
        o.separator 'Cross-platform metadata cleaner. Strips EXIF, IPTC, XMP, GPS,'
        o.separator 'MakerNotes, ID3, document properties, etc. — uses ExifTool, mat2'
        o.separator 'and qpdf together for maximum coverage.'
        o.separator ''

        # Each `o.on` registers a flag. The block runs when that flag is
        # found in argv. `_v` is the captured value (unused for booleans).
        o.separator 'Modes:'
        o.on('--inspect',    'Only show metadata, do not modify files')      { @options[:inspect_only] = true }
        o.on('--json',       'Output as JSON (with --inspect)')              { @options[:format] = :json }
        o.on('--dry-run',    'Simulate cleaning, show diff, write nothing') { @options[:dry_run] = true }

        o.separator ''
        o.separator 'Output:'
        o.on('-i', '--in-place', 'Overwrite originals (default: write *_clean.<ext>)') { @options[:in_place] = true }
        o.on('--no-backup',      "Don't keep a .bak when --in-place")                  { @options[:no_backup] = true }

        o.separator ''
        o.separator 'Selection:'
        o.on('-r', '--recursive',     'Recurse into directories')              { @options[:recursive] = true }
        o.on('--follow-symlinks',     'Follow symlinks (default: skip them)') { @options[:follow_symlinks] = true }
        # `--types=LIST, Array` tells OptionParser to split the value on
        # commas. So `--types=jpg,png` arrives as ["jpg", "png"].
        o.on('--types=LIST', Array,   'Only process these extensions (e.g. jpg,png,pdf)') do |v|
          @options[:types] = v.map { |x| x.to_s.downcase.delete('.') }
        end

        o.separator ''
        o.separator 'Tool selection:'
        o.on('--exiftool-only', 'Use only ExifTool (skip mat2 and qpdf)') { @options[:exiftool_only] = true }
        o.on('--no-mat2',       'Disable mat2 even if available')         { @options[:no_mat2] = true }
        o.on('--no-qpdf',       'Disable qpdf even if available')         { @options[:no_qpdf] = true }
        o.on('--no-exiftool',   'Disable ExifTool')                       { @options[:no_exiftool] = true }

        o.separator ''
        o.separator 'Preservation:'
        o.on('--keep-orientation',   'Preserve EXIF Orientation tag') { @options[:keep_orientation] = true }
        o.on('--keep-color-profile', 'Preserve embedded ICC profile') { @options[:keep_color_profile] = true }

        o.separator ''
        o.separator 'Verification:'
        o.on('-f', '--force',     'Skip confirmation prompt')              { @options[:force] = true }
        o.on('--strict-verify',   'Exit non-zero if privacy tags survive') { @options[:strict_verify] = true }

        o.separator ''
        o.separator 'Other:'
        o.on('-h', '--help')    { puts o; exit }
        o.on('-v', '--version') do
          puts "metaclean #{Metaclean::VERSION}"
          # `&.split&.last` is safe-navigation: if `Qpdf.version` is nil
          # (qpdf not installed), the chain short-circuits to nil rather
          # than blowing up with NoMethodError.
          puts "  exiftool: #{Exiftool.version || 'not found'}"
          puts "  mat2:     #{Mat2.version     || 'not found'}"
          puts "  qpdf:     #{Qpdf.version&.split&.last || 'not found'}"
          exit
        end
      end

      # `parse!` mutates @argv in place: known flags are consumed,
      # positional args (file paths) are left behind.
      begin
        parser.parse!(@argv)
      rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
        # Bad flag → show the message + the help text and exit non-zero.
        warn Display.error(e.message)
        warn parser
        exit 1
      end

      # No paths after flags → user probably ran `metaclean` with no args.
      # Show help and exit non-zero so scripts notice.
      if @argv.empty?
        puts parser
        exit 1
      end

      @paths = @argv.dup
    end
  end
end
