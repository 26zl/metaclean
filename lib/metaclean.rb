# frozen_string_literal: true

# Library entry point. require order matters: dependencies before dependents.

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
