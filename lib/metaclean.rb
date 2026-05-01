# frozen_string_literal: true

# ───────────────────────────────────────────────────────────────────────────
# lib/metaclean.rb — the library's "front door".
#
# In Ruby, a module is a namespace. We put everything inside `Metaclean::*`
# so we don't pollute the global namespace and so it's obvious where each
# piece belongs.
#
# The `require` order matters: a file can only reference constants from
# files already loaded. We load the smallest pieces first, then the bigger
# ones that depend on them.
# ───────────────────────────────────────────────────────────────────────────

require 'metaclean/version'   # just defines VERSION
require 'metaclean/display'   # ANSI colors and formatters (no deps)
require 'metaclean/exiftool'  # ExifTool wrapper
require 'metaclean/mat2'      # mat2 wrapper
require 'metaclean/qpdf'      # qpdf wrapper
require 'metaclean/strategy'  # picks which tools run for each file type
require 'metaclean/runner'    # orchestrates a clean across many files
require 'metaclean/cli'       # parses ARGV and calls Runner

module Metaclean
  # Custom exception classes. Inheriting from StandardError lets callers do
  # `rescue Metaclean::Error` to catch any of our errors without accidentally
  # catching things like NoMemoryError or SystemExit.
  class Error < StandardError; end

  # A more specific error so the CLI can show a tailored install hint when
  # ExifTool itself is missing.
  class ExiftoolMissing < Error; end
end
