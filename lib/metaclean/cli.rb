# frozen_string_literal: true

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
        dry_run:      false,
        quiet:        false,
        allow_icc_metadata: false,
        redact_values: !$stdout.tty?
      }
      @paths = []
    end

    def run
      parse!
      Display.configure(quiet: @options[:quiet], redact_values: @options[:redact_values])
      Metaclean.ensure_tools!(in_place: @options[:in_place])
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
      warn Display.error(e.message)
      exit 1
    rescue Interrupt
      warn "\n#{Display.error('Interrupted.')}"
      exit 130
    end

    private

    def parse!
      parser = option_parser

      begin
        parser.parse!(@argv)
      rescue OptionParser::ParseError => e
        warn Display.error(e.message)
        warn parser
        exit 1
      end

      if @argv.empty?
        Display.banner
        puts parser
        exit 1
      end

      incompatible = []
      incompatible << '--dry-run' if @options[:dry_run]
      incompatible << '--in-place' if @options[:in_place]
      incompatible << '--force' if @options[:force]
      if @options[:inspect_only] && incompatible.any?
        warn Display.error("--inspect cannot be combined with #{incompatible.join(', ')}")
        exit 1
      end

      @paths = @argv.dup
    end

    def option_parser
      OptionParser.new do |o|
        o.banner = 'Usage: metaclean [options] <path> [<path>...]'
        o.separator ''
        o.separator 'Metadata cleaner. Strips EXIF, IPTC, XMP, GPS,'
        o.separator 'MakerNotes, ID3, document properties, etc. — uses ExifTool, mat2,'
        o.separator 'qpdf and ffmpeg together for maximum coverage.'
        o.separator ''

        o.separator 'Modes:'
        o.on('--inspect', 'Only show metadata, do not modify files')     { @options[:inspect_only] = true }
        o.on('--dry-run', 'Simulate on a private temporary copy; keep no output') { @options[:dry_run] = true }

        o.separator ''
        o.separator 'Output:'
        o.on('-i', '--in-place', 'Overwrite originals (keeps a .bak; default: *_clean.<ext>)') { @options[:in_place] = true }
        o.on('-r', '--recursive', 'Recurse into directories') { @options[:recursive] = true }
        o.on('-f', '--force',     'Skip confirmation prompt')  { @options[:force] = true }
        o.on('-q', '--quiet',     'Suppress normal output; errors and warnings remain') { @options[:quiet] = true }
        o.on('--redact-values',   'Hide metadata values in tables and diffs') { @options[:redact_values] = true }
        o.on('--show-values',     'Show metadata values even when output is redirected') { @options[:redact_values] = false }
        o.on('--allow-icc-metadata',
             'Keep non-standard ICC profile text (standard color spaces clean anyway)') do
          @options[:allow_icc_metadata] = true
        end

        o.separator ''
        o.separator 'Other:'
        o.on('-h', '--help')    { Display.banner; puts o; exit }
        o.on('-v', '--version') do
          Display.banner
          puts "metaclean #{Metaclean::VERSION}"
          puts "  exiftool: #{Display.printable(Exiftool.version || 'not found')}"
          puts "  mat2:     #{Display.printable(Mat2.version     || 'not found')}"
          puts "  qpdf:     #{Display.printable(Qpdf.version     || 'not found')}"
          puts "  ffmpeg:   #{Display.printable(Ffmpeg.version   || 'not found')}"
          exit
        end
        o.separator ''
        o.separator 'Use -- before a filename that begins with "-".'
      end
    end
  end
end
