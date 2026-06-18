# frozen_string_literal: true

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
        recursive:    false,
        in_place:     false,
        force:        false,
        inspect_only: false,
        dry_run:      false
      }
      @paths = []
    end

    # Top-level dispatcher. Catches our errors and exits with codes that
    # shells/CI can act on:
    #   0  → success
    #   1  → general failure
    #   2  → a required tool (exiftool/mat2/qpdf) is missing (install hint shown)
    #   130→ user pressed Ctrl-C (matches the standard SIGINT exit code)
    def run
      parse!
      # Refuse to run unless all three external tools are present (see
      # Metaclean.ensure_tools!). --help/--version already exited inside parse!,
      # so this only gates an actual inspect/clean.
      Metaclean.ensure_tools!
      runner = Runner.new(@options)
      if @options[:inspect_only]
        runner.inspect_paths(@paths)
      else
        runner.clean_paths(@paths)
      end
    rescue ToolsMissing => e
      warn Display.error('Missing required tools')
      warn e.message
      exit 2
    rescue Error, SystemCallError => e
      # Errno::* (disk full, permission denied, read-only fs) is a SIBLING of
      # our Error, not a subclass; naming it here gives filesystem failures a
      # clean message + exit 1 instead of a raw backtrace.
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
        o.separator 'Metadata cleaner. Strips EXIF, IPTC, XMP, GPS,'
        o.separator 'MakerNotes, ID3, document properties, etc. — uses ExifTool, mat2'
        o.separator 'and qpdf together for maximum coverage.'
        o.separator ''

        # Each `o.on` registers a flag. The block runs when that flag is seen.
        o.separator 'Modes:'
        o.on('--inspect', 'Only show metadata, do not modify files')     { @options[:inspect_only] = true }
        o.on('--dry-run', 'Simulate cleaning, show diff, write nothing') { @options[:dry_run] = true }

        o.separator ''
        o.separator 'Output:'
        o.on('-i', '--in-place', 'Overwrite originals (keeps a .bak; default: *_clean.<ext>)') { @options[:in_place] = true }
        o.on('-r', '--recursive', 'Recurse into directories') { @options[:recursive] = true }
        o.on('-f', '--force',     'Skip confirmation prompt')  { @options[:force] = true }

        o.separator ''
        o.separator 'Other:'
        o.on('-h', '--help')    { puts o; exit }
        o.on('-v', '--version') do
          puts "metaclean #{Metaclean::VERSION}"
          # Each `.version` returns the bare version number or nil when the
          # tool isn't installed; `|| 'not found'` handles the nil.
          puts "  exiftool: #{Exiftool.version || 'not found'}"
          puts "  mat2:     #{Mat2.version     || 'not found'}"
          puts "  qpdf:     #{Qpdf.version     || 'not found'}"
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
