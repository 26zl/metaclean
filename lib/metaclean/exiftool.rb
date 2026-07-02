# frozen_string_literal: true

require 'json'

module Metaclean
  module Exiftool
    module_function

    def available?
      return @available if defined?(@available)

      out, _err, status = Metaclean.capture3(
        'exiftool', '-ver',
        timeout: Metaclean::PROBE_TIMEOUT,
        max_output: Metaclean::PROBE_MAX_OUTPUT_BYTES
      )
      @available = status.success?
      @version = @available ? out.strip : nil
      @available
    rescue Errno::ENOENT, Error
      @version = nil
      @available = false
    end

    def version
      available? ? @version : nil
    end

    def read(path)
      out, err, status = Metaclean.capture3(
        'exiftool', '-j', '-G1', '-a', '-u', '-s', '-n', '-api', 'largefilesupport=1',
        Metaclean.safe_path(path)
      )
      raise Error, "ExifTool read failed: #{read_error_detail(out, err)}" unless status.success?

      data = JSON.parse(out)
      raise Error, 'Unexpected ExifTool output (expected a JSON array)' unless data.is_a?(Array)

      scrub_encoding(data.first || {})
    rescue JSON::ParserError => e
      raise Error, "Could not parse ExifTool output: #{e.message}"
    end

    def read_error_detail(out, err)
      return err.strip unless err.strip.empty?

      data = JSON.parse(out)
      entry = data.is_a?(Array) ? data.first : nil
      detail = entry && (entry['ExifTool:Error'] || entry['Error'])
      detail ? detail.to_s.strip : 'unknown error'
    rescue JSON::ParserError
      'unknown error'
    end

    def scrub_encoding(obj)
      case obj
      when String then obj.valid_encoding? ? obj : obj.scrub
      when Array  then obj.map { |e| scrub_encoding(e) }
      when Hash   then obj.transform_values { |v| scrub_encoding(v) }
      else obj
      end
    end

    WRITE_UNSUPPORTED_RE = /
      writing\sof\s(?:this\stype\sof\s|[^\s]+\s)?files?\sis\snot\s(?:yet\s)?supported |
      can't\scurrently\swrite |
      does\snot\syet\ssupport\swriting
    /ix

    PRESERVE_TAGS = %w[Orientation ICC_Profile].freeze

    def strip!(path, also_delete: [])
      FileOps.regular_stat!(path)
      args = ['exiftool', '-all=', '-gps:all=']
      also_delete.each { |tag| args << "-#{tag}=" }
      args.concat(['-tagsfromfile', '@'])
      PRESERVE_TAGS.each { |tag| args << "-#{tag}" }
      args.concat(['-overwrite_original', '-q', '-q', '-api', 'largefilesupport=1', Metaclean.safe_path(path)])

      _out, err, status = Metaclean.capture3(*args)
      if status.success?
        FileOps.validate_output!(path)
        return true
      end
      return :unsupported if err.match?(WRITE_UNSUPPORTED_RE)

      raise Error, "ExifTool strip failed: #{err.strip}"
    end
  end
end
