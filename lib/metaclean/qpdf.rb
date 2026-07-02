# frozen_string_literal: true

require 'json'

module Metaclean
  module Qpdf
    module_function

    def available?
      return @available if defined?(@available)

      out, _err, status = Metaclean.capture3(
        'qpdf', '--version',
        timeout: Metaclean::PROBE_TIMEOUT,
        max_output: Metaclean::PROBE_MAX_OUTPUT_BYTES
      )
      @available = status.success?
      @version = @available ? out.lines.first.to_s.strip.split.last : nil
      @available
    rescue Errno::ENOENT, Error
      @version = nil
      @available = false
    end

    def version
      available? ? @version : nil
    end

    def rebuild!(path)
      raise Error, 'qpdf not available' unless available?

      source = FileOps.regular_stat!(path)
      ensure_no_attachments!(path)
      FileOps.with_private_workspace(path, 'qpdf') do |workspace|
        tmp = File.join(workspace, 'output.pdf')
        _out, err, status = Metaclean.capture3(
          'qpdf', '--linearize', '--object-streams=generate',
          '--remove-unreferenced-resources=yes',
          Metaclean.safe_path(path), Metaclean.safe_path(tmp)
        )

        success = status.success? || status.exitstatus == 3
        raise Error, "qpdf failed: #{err.strip}" unless success && File.exist?(tmp)

        FileOps.validate_output!(tmp)
        validate_pdf!(tmp)
        FileOps.ensure_same_file!(path, source)
        FileOps.restore_metadata(tmp, source)
        File.rename(tmp, path)
        true
      end
    end

    def ensure_no_attachments!(path)
      out, err, status = Metaclean.capture3(
        'qpdf', '--json', '--json-key=attachments', Metaclean.safe_path(path)
      )
      success = status.success? || status.exitstatus == 3
      raise Error, "qpdf could not inspect PDF attachments: #{err.strip}" unless success

      attachments = JSON.parse(out).fetch('attachments')
      raise Error, 'Unexpected qpdf attachment inventory' unless attachments.is_a?(Hash)
      return if attachments.empty?

      raise Error, 'PDF contains embedded attachments whose nested metadata cannot be verified'
    rescue JSON::ParserError, KeyError => e
      raise Error, "Could not parse qpdf attachment inventory: #{e.message}"
    end

    def validate_pdf!(path)
      _out, err, status = Metaclean.capture3(
        'qpdf', '--check', Metaclean.safe_path(path)
      )
      return true if status.success? || status.exitstatus == 3

      raise Error, "qpdf produced an invalid PDF: #{err.strip}"
    end
  end
end
