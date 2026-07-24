# frozen_string_literal: true

require 'open3'

require 'metaclean/version'
require 'metaclean/display'
require 'metaclean/file_ops'
require 'metaclean/exiftool'
require 'metaclean/mat2'
require 'metaclean/qpdf'
require 'metaclean/ffmpeg'
require 'metaclean/strategy'
require 'metaclean/discovery'
require 'metaclean/committer'
require 'metaclean/runner'
require 'metaclean/cli'

module Metaclean
  class Error < StandardError; end

  class ToolsMissing < Error; end

  def self.safe_path(path)
    s = path.to_s
    s.start_with?('-') ? File.join('.', s) : s
  end

  COMMAND_TIMEOUT = 120
  MAX_OUTPUT_BYTES = 64 * 1024 * 1024
  PROBE_TIMEOUT = 10
  PROBE_MAX_OUTPUT_BYTES = 1024 * 1024
  READ_CHUNK = 64 * 1024

  def self.command_timeout
    override = ENV['METACLEAN_TIMEOUT'].to_i
    override.positive? ? override : COMMAND_TIMEOUT
  end

  def self.capture3(*cmd, timeout: command_timeout, max_output: MAX_OUTPUT_BYTES)
    Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
      out_t = err_t = deadline = nil
      begin
        stdin.close
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        out_t = read_capped(stdout, max_output, wait_thr)
        err_t = read_capped(stderr, max_output, wait_thr)

        if wait_thr.join(timeout).nil?
          kill_group(wait_thr)
          drain_readers(out_t, err_t, deadline)
          raise Error, "#{cmd.first} timed out after #{timeout}s"
        end

        unless drain_readers(out_t, err_t, deadline)
          kill_group(wait_thr)
          drain_readers(out_t, err_t, deadline)
          raise Error, "#{cmd.first} timed out after #{timeout}s"
        end

        out, out_over = out_t.value
        err, err_over = err_t.value
        raise Error, "#{cmd.first} exceeded the #{max_output}-byte output limit" if out_over || err_over

        [out, err, wait_thr.value]
      rescue Interrupt
        kill_group(wait_thr)
        drain_readers(out_t, err_t, deadline) if out_t && err_t && deadline
        raise
      end
    end
  end

  def self.drain_readers(out_t, err_t, deadline)
    [out_t, err_t].all? do |t|
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      remaining = 0.1 if remaining < 0.1
      !t.join(remaining).nil?
    end
  end

  def self.read_capped(io, limit, wait_thr)
    Thread.new do
      buf = +''
      over = false
      while (chunk = io.read(READ_CHUNK))
        next if over

        buf << chunk
        next unless buf.bytesize > limit

        over = true
        buf = buf.byteslice(0, limit)
        kill_group(wait_thr)
      end
      [buf, over]
    end
  end

  def self.kill_group(wait_thr)
    Process.kill('-TERM', wait_thr.pid)
    Process.kill('-KILL', wait_thr.pid) unless wait_thr.join(2)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def self.ext_of(path)
    File.extname(path.to_s).downcase.delete('.')
  end

  TMP_MARKER = '.metaclean.tmp.'

  CLEAN_SUFFIX = '_clean'

  CLEAN_OUTPUT_RE = /#{Regexp.escape(CLEAN_SUFFIX)}(?:_\d+)?(?:\.[^.]+)?\z/

  def self.ensure_tools!(in_place: false)
    missing = []
    missing << 'exiftool' unless Exiftool.available?
    missing << 'mat2'     unless Mat2.available?
    missing << 'qpdf'     unless Qpdf.available?
    missing << 'ffmpeg (with ffprobe)' unless Ffmpeg.available?
    missing << 'cp with metadata preservation' if in_place && !FileOps.metadata_copy_supported?
    return if missing.empty?

    raise ToolsMissing, <<~MSG
      Missing required tool(s): #{missing.join(', ')}

      metaclean needs ExifTool, mat2, qpdf and ffmpeg together. Install all four:
        macOS:          brew install exiftool mat2 qpdf ffmpeg
        Debian/Ubuntu:  sudo apt install libimage-exiftool-perl mat2 qpdf ffmpeg
        Fedora:         sudo dnf install perl-Image-ExifTool mat2 qpdf ffmpeg
        Arch:           sudo pacman -S perl-image-exiftool mat2 qpdf ffmpeg
        Windows:        use WSL2 (https://learn.microsoft.com/windows/wsl/install) + the Debian/Ubuntu line

      --in-place additionally requires the POSIX cp utility supplied by macOS or coreutils on Linux.
    MSG
  end
end
