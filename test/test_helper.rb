# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'metaclean'
require 'tmpdir'
require 'minitest/autorun'
require 'minitest/mock' # provides Object#stub used to fake tool availability
