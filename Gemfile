# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.2'

# metaclean has zero runtime gem dependencies — it shells out to ExifTool.
# This Gemfile exists only for development / packaging.
group :development do
  gem 'bundler-audit', require: false # dependency CVE audit; gates the release workflow
  gem 'minitest', '~> 5.0' # test framework (also a Ruby default gem)
  gem 'rake'
  gem 'rubocop', '~> 1.87.0', require: false # lint; pinned so new cops can't surprise CI
end
