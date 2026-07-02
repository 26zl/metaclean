# frozen_string_literal: true

module Metaclean
  module Mat2
    SUPPORTED_EXTS = %w[
      epub pdf odc odf odg odi odp ods odt pptx xlsx docx torrent ncx tar
      xht xhtml zip flac m3a mp2a mp3 mp2 m2a mpga oga spx ogg opus
      aifc aiff aif wav bmp gif heic jpg jpe jpeg png svgz svg tiff tif
      webp ppm css htm html text txt in def list log conf
      mp4 mp4v mpg4 m4v wmv avi
    ].freeze

    UNSUPPORTED_RE = /(not supported|isn't supported|cannot be cleaned|unsupported file)/i.freeze

    module_function

    def available?
      return @available if defined?(@available)

      out, _err, status = Metaclean.capture3(
        'mat2', '--version',
        timeout: Metaclean::PROBE_TIMEOUT,
        max_output: Metaclean::PROBE_MAX_OUTPUT_BYTES
      )
      @available = status.success?
      @version = @available ? out.strip.split.last : nil
      @available
    rescue Errno::ENOENT, Error
      @version = nil
      @available = false
    end

    def version
      available? ? @version : nil
    end

    def supports?(path)
      return false unless available?

      SUPPORTED_EXTS.include?(Metaclean.ext_of(path))
    end

    def strip!(path)
      raise Error, 'mat2 not available' unless available?

      source = FileOps.regular_stat!(path)
      FileOps.with_private_workspace(path, 'mat2') do |workspace|
        work = File.join(workspace, "input#{File.extname(path)}")
        FileOps.copy_exclusive(path, work, preserve: true, expected: source)
        cleaned = cleaned_path_for(work)
        out, err, status = Metaclean.capture3('mat2', Metaclean.safe_path(work))

        if status.success?
          return :no_metadata unless File.exist?(cleaned)

          FileOps.validate_output!(cleaned)
          FileOps.ensure_same_file!(path, source)
          FileOps.restore_metadata(cleaned, source)
          File.rename(cleaned, path)
          return true
        end

        combined = "#{out}\n#{err}"
        return :unsupported if combined.match?(UNSUPPORTED_RE)

        raise Error, "mat2 failed: #{err.strip.empty? ? out.strip : err.strip}"
      end
    end

    def cleaned_path_for(path)
      dir  = File.dirname(path)
      ext  = File.extname(path)
      stem = File.basename(path, ext)
      File.join(dir, "#{stem}.cleaned#{ext}")
    end
  end
end
