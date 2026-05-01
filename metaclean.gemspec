# frozen_string_literal: true

require_relative 'lib/metaclean/version'

Gem::Specification.new do |s|
  s.name        = 'metaclean'
  s.version     = Metaclean::VERSION
  s.summary     = 'Cross-platform CLI that strips file metadata with ExifTool, mat2 and qpdf.'
  s.description = <<~DESC
    metaclean is a small Ruby CLI that wraps ExifTool, mat2 and qpdf to strip
    removable embedded tags (EXIF, IPTC, XMP, GPS, MakerNotes, ID3, document
    properties, etc.) from images, audio, video, PDFs and Office documents —
    and shows a before/after diff of what was removed.
  DESC
  s.authors     = ['26zl']
  s.homepage    = 'https://github.com/26zl/metaclean'
  s.license     = 'MIT'
  s.required_ruby_version = '>= 3.2'

  s.files       = Dir['lib/**/*.rb', 'bin/*', 'README.md', 'LICENSE']
  s.bindir      = 'bin'
  s.executables = ['metaclean']
  s.require_paths = ['lib']
  s.metadata = {
    'allowed_push_host' => 'https://rubygems.org',
    'bug_tracker_uri' => 'https://github.com/26zl/metaclean/issues',
    'changelog_uri' => 'https://github.com/26zl/metaclean/releases',
    'source_code_uri' => 'https://github.com/26zl/metaclean',
    'rubygems_mfa_required' => 'true'
  }

  s.requirements << 'ExifTool (https://exiftool.org) on PATH'
end
