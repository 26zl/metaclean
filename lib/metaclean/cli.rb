# frozen_string_literal: true

# CLI argument parser. Uses stdlib OptionParser (zero deps) over a gem like Thor.

require 'optparse'

module Metaclean
  class CLI
    def self.start(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup
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
    #   2  → a required tool (exiftool/mat2/qpdf/ffmpeg) is missing (install hint shown)
    #   130→ user pressed Ctrl-C (matches the standard SIGINT exit code)
    def run
      parse!
      # Refuse to run unless all four external tools are present (see
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
      # Print a clean message instead of a stack trace.
      warn "\n#{Display.error('Interrupted.')}"
      exit 130
    end

    private

    def parse!
      parser = OptionParser.new do |o|
        o.banner = 'Usage: metaclean [options] <path> [<path>...]'
        o.separator ''
        o.separator 'Metadata cleaner. Strips EXIF, IPTC, XMP, GPS,'
        o.separator 'MakerNotes, ID3, document properties, etc. — uses ExifTool, mat2,'
        o.separator 'qpdf and ffmpeg together for maximum coverage.'
        o.separator ''

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
        o.on('-h', '--help')    { Display.banner; puts o; exit }
        o.on('-v', '--version') do
          Display.banner
          puts "metaclean #{Metaclean::VERSION}"
          # Route tool versions (from the binaries' own stdout) through printable,
          # like every other output path, so a tool emitting ANSI/OSC control
          # bytes on its version line can't inject the terminal.
          puts "  exiftool: #{Display.printable(Exiftool.version || 'not found')}"
          puts "  mat2:     #{Display.printable(Mat2.version     || 'not found')}"
          puts "  qpdf:     #{Display.printable(Qpdf.version     || 'not found')}"
          puts "  ffmpeg:   #{Display.printable(Ffmpeg.version   || 'not found')}"
          exit
        end
      end

      begin
        parser.parse!(@argv)
      rescue OptionParser::ParseError => e
        # Any malformed flag — unknown, missing argument, or an ambiguous
        # abbreviation like `--i` (matches both --inspect and --in-place) —
        # shows the message + help and exits non-zero, never a raw backtrace.
        # ParseError is the base class of all of OptionParser's error types.
        warn Display.error(e.message)
        warn parser
        exit 1
      end

      # No paths: show help, exit non-zero so scripts notice.
      if @argv.empty?
        Display.banner
        puts parser
        exit 1
      end

      @paths = @argv.dup
    end
  end
end
