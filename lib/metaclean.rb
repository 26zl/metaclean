# frozen_string_literal: true

# Library entry point. require order matters: dependencies before dependents.

require 'open3'

require 'metaclean/version'
require 'metaclean/display'
require 'metaclean/exiftool'
require 'metaclean/mat2'
require 'metaclean/qpdf'
require 'metaclean/ffmpeg'
require 'metaclean/strategy'
require 'metaclean/runner'
require 'metaclean/cli'

module Metaclean
  class Error < StandardError; end

  # Raised by ensure_tools! when any of the four required external tools is not
  # on PATH. metaclean runs ExifTool, mat2, qpdf and ffmpeg together and refuses
  # to run without all of them.
  class ToolsMissing < Error; end

  # A path beginning with "-" is misread as an *option* by the tools we shell
  # out to — e.g. exiftool's `-config FILE` loads and runs arbitrary Perl.
  # Open3 argument arrays bypass the shell, but NOT the invoked tool's own
  # option parser. Prefixing a leading-dash relative path with "./" makes it
  # unambiguously a filename to every tool. Absolute paths and normal names
  # pass through untouched. Used at every shell-out boundary.
  def self.safe_path(path)
    s = path.to_s
    s.start_with?('-') ? File.join('.', s) : s
  end

  # External tools can hang, or run away producing endless output, on a corrupt
  # or hostile file. Every OPERATIONAL shell-out (read/strip/rebuild) goes through
  # this instead of Open3.capture3 so one bad file is bounded on BOTH axes — by
  # wall-clock (COMMAND_TIMEOUT) and by captured bytes (MAX_OUTPUT_BYTES) — rather
  # than hanging or exhausting memory and taking the whole batch with it. The
  # quick availability probes (`-ver`/`--version`) stay on plain capture3: fixed
  # args, no file input, nothing to hang on.
  COMMAND_TIMEOUT = 120 # seconds
  # Per stream (stdout AND stderr). Far above any legitimate output from the
  # tools' invocations here (metadata JSON / `-q` strips / `-v error` muxes), so
  # tripping it means a runaway, not a real result.
  MAX_OUTPUT_BYTES = 64 * 1024 * 1024
  READ_CHUNK = 64 * 1024

  # Drop-in replacement for Open3.capture3 that returns the same [out, err,
  # status] triple but kills the command (and anything it spawned) if it runs
  # past `timeout` OR floods more than `max_output` bytes on either stream.
  def self.capture3(*cmd, timeout: COMMAND_TIMEOUT, max_output: MAX_OUTPUT_BYTES)
    Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      # Drain both pipes concurrently: a tool that fills one pipe buffer would
      # otherwise block forever before exiting, and `join` below would never see
      # it finish even though it isn't actually hung.
      out_t = read_capped(stdout, max_output, wait_thr)
      err_t = read_capped(stderr, max_output, wait_thr)

      if wait_thr.join(timeout).nil?
        kill_group(wait_thr)
        out_t.join(2)
        err_t.join(2)
        raise Error, "#{cmd.first} timed out after #{timeout}s"
      end

      out, out_over = out_t.value
      err, err_over = err_t.value
      raise Error, "#{cmd.first} exceeded the #{max_output}-byte output limit" if out_over || err_over

      [out, err, wait_thr.value]
    end
  end

  # Read an IO into a String in a thread, but stop accumulating once it passes
  # `limit` bytes — and kill the command then, so a flooding stream is cut off
  # promptly instead of waiting out the full timeout. After the cap is hit it
  # keeps draining (discarding) so the dying child isn't blocked on a full pipe.
  # Returns [string, overflowed?].
  def self.read_capped(io, limit, wait_thr)
    Thread.new do
      buf = +''
      over = false
      while (chunk = io.read(READ_CHUNK))
        next if over # past the cap: drain & discard so the child can exit

        buf << chunk
        next unless buf.bytesize > limit

        over = true
        buf = buf.byteslice(0, limit)
        kill_group(wait_thr)
      end
      [buf, over]
    end
  end

  # SIGTERM the child's whole process group — pgroup:true made the child the
  # group leader, so any helpers it forked are signalled too — escalating to
  # SIGKILL if it ignores TERM. A negative pid targets the group.
  def self.kill_group(wait_thr)
    Process.kill('-TERM', wait_thr.pid)
    Process.kill('-KILL', wait_thr.pid) unless wait_thr.join(2)
  rescue Errno::ESRCH, Errno::EPERM
    nil # already gone, or not permitted to signal it — nothing more to do
  end

  # Lower-cased, dot-stripped extension used for FORMAT ROUTING decisions
  # (Strategy#tools_for, Strategy#mat2_essential?, Mat2.supports?). One
  # definition so every routing path normalizes the extension identically —
  # a future tweak (double extensions, locale-safe downcasing) lands once.
  def self.ext_of(path)
    File.extname(path.to_s).downcase.delete('.')
  end

  # Marker embedded in every staging-temp filename (Runner, Ffmpeg, Qpdf) and
  # matched by Runner#skip?, so a leftover temp from an interrupted run is
  # ignored on a later directory scan. One literal keeps the producers and the
  # matcher from drifting (qpdf previously embedded a divergent
  # ".metaclean.qpdf.tmp." that didn't contain this marker).
  TMP_MARKER = '.metaclean.tmp.'

  # Suffix of the default "<name>_clean.<ext>" outputs. Runner#build_clean_path
  # writes it; CLEAN_OUTPUT_RE derives the loop-prevention match from it so the
  # producer and Runner#skip? can't disagree.
  CLEAN_SUFFIX = '_clean'

  # Matches our own "<name>_clean.<ext>" outputs (with optional "_N" collision
  # counter) so a recursive re-run doesn't re-clean them. Compiled once here,
  # in the module body that runs after the requires, so CLEAN_SUFFIX exists.
  CLEAN_OUTPUT_RE = /#{Regexp.escape(CLEAN_SUFFIX)}(_\d+)?\.[^.]+\z/

  # Preflight: all four tools must be installed. We run them together for full
  # coverage and to verify the strip, so a partial toolchain is not "good enough"
  # — bail with one clear message naming what's missing and how to install
  # everything. Called once by the CLI before any inspect/clean work.
  def self.ensure_tools!
    missing = []
    missing << 'exiftool' unless Exiftool.available?
    missing << 'mat2'     unless Mat2.available?
    missing << 'qpdf'     unless Qpdf.available?
    missing << 'ffmpeg'   unless Ffmpeg.available?
    return if missing.empty?

    raise ToolsMissing, <<~MSG
      Missing required tool(s): #{missing.join(', ')}

      metaclean needs ExifTool, mat2, qpdf and ffmpeg together. Install all four:
        macOS:          brew install exiftool mat2 qpdf ffmpeg
        Debian/Ubuntu:  sudo apt install libimage-exiftool-perl mat2 qpdf ffmpeg
        Fedora:         sudo dnf install perl-Image-ExifTool mat2 qpdf ffmpeg
        Arch:           sudo pacman -S perl-image-exiftool mat2 qpdf ffmpeg
        Windows:        use WSL2 (https://learn.microsoft.com/windows/wsl/install) + the Debian/Ubuntu line
    MSG
  end
end
