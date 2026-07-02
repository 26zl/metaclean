# frozen_string_literal: true

require 'json'

module Metaclean
  module Ffmpeg
    NESTED_IMAGE_CODECS = %w[bmp gif mjpeg mjpegb png tiff webp].freeze

    module_function

    def available?
      return @available if defined?(@available)

      out, _err, status = Metaclean.capture3(
        'ffmpeg', '-version',
        timeout: Metaclean::PROBE_TIMEOUT,
        max_output: Metaclean::PROBE_MAX_OUTPUT_BYTES
      )
      _probe_out, _probe_err, probe_status = Metaclean.capture3(
        'ffprobe', '-version',
        timeout: Metaclean::PROBE_TIMEOUT,
        max_output: Metaclean::PROBE_MAX_OUTPUT_BYTES
      )
      @available = status.success? && probe_status.success?
      @version = @available ? out.lines.first.to_s.split[2] : nil
      @available
    rescue Errno::ENOENT, Error
      @version = nil
      @available = false
    end

    def version
      available? ? @version : nil
    end

    def strip!(path)
      raise Error, 'ffmpeg not available' unless available?

      source = FileOps.regular_stat!(path)
      structure = probe_structure(path)
      reject_unverifiable_streams!(structure[:streams])
      FileOps.with_private_workspace(path, 'ffmpeg') do |workspace|
        tmp = File.join(workspace, "output#{File.extname(path)}")
        args = [
          'ffmpeg', '-y', '-v', 'error', '-nostdin', '-i', file_url(path),
          '-map', '0', '-map_metadata', '-1',
          '-map_chapters', structure[:chapters].positive? ? '0' : '-1'
        ]
        args.concat(['-metadata:c', 'title=']) if structure[:chapters].positive?
        append_safe_stream_languages(args, structure[:streams])
        args.concat(['-c', 'copy', file_url(tmp)])

        _out, err, status = Metaclean.capture3(*args)
        raise Error, "ffmpeg failed: #{err.strip}" unless status.success? && File.exist?(tmp)

        FileOps.validate_output!(tmp)
        ensure_structure_preserved!(structure, probe_structure(tmp))
        FileOps.ensure_same_file!(path, source)
        FileOps.restore_metadata(tmp, source)
        File.rename(tmp, path)
        true
      end
    end

    def probe_structure(path)
      out, err, status = Metaclean.capture3(
        'ffprobe', '-v', 'error', '-show_streams', '-show_chapters',
        '-of', 'json', file_url(path)
      )
      raise Error, "ffprobe failed: #{err.strip}" unless status.success?

      data = JSON.parse(out)
      streams = data.fetch('streams', [])
      chapters = data.fetch('chapters', [])
      raise TypeError unless streams.is_a?(Array) && chapters.is_a?(Array)

      { streams: streams, chapters: chapters.size }
    rescue JSON::ParserError, KeyError, TypeError => e
      raise Error, "Could not parse ffprobe output: #{e.message}"
    end

    def reject_unverifiable_streams!(streams)
      video_streams = streams.count { |stream| stream['codec_type'] == 'video' }
      nested = streams.any? do |stream|
        tags = stream['tags'].is_a?(Hash) ? stream['tags'] : {}
        disposition = stream['disposition'].is_a?(Hash) ? stream['disposition'] : {}
        nested_image = stream['codec_type'] == 'video' &&
                       NESTED_IMAGE_CODECS.include?(stream['codec_name']) &&
                       (video_streams > 1 || streams.any? { |candidate| candidate['codec_type'] == 'audio' })
        stream['codec_type'] == 'attachment' ||
          nested_image ||
          disposition['attached_pic'].to_i == 1 ||
          !tags['filename'].to_s.empty? ||
          !tags['mimetype'].to_s.empty?
      end
      return unless nested

      raise Error, 'Matroska contains attachments or cover art whose nested metadata cannot be verified'
    end

    def ensure_structure_preserved!(before, after)
      before_signatures = stream_signatures(before[:streams])
      after_signatures = stream_signatures(after[:streams])
      unless before_signatures == after_signatures && before[:chapters] == after[:chapters]
        raise Error, 'ffmpeg output changed the stream or chapter structure'
      end
    end

    def stream_signatures(streams)
      streams.map { |stream| [stream['codec_type'], stream['codec_name']] }
    end

    def append_safe_stream_languages(args, streams)
      streams.each do |stream|
        index = Integer(stream.fetch('index'))
        tags = stream['tags'].is_a?(Hash) ? stream['tags'] : {}
        language = tags['language'].to_s.downcase
        if language.match?(/\A[a-z]{2,3}(?:-[a-z0-9]{2,8})*\z/)
          args.concat(["-metadata:s:#{index}", "language=#{language}"])
        end
      end
    rescue KeyError, TypeError, ArgumentError => e
      raise Error, "Unexpected ffprobe stream data: #{e.message}"
    end

    def file_url(path)
      "file:#{File.expand_path(path)}"
    end
  end
end
