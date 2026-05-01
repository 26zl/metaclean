# frozen_string_literal: true

require 'rake/clean'
require 'shellwords'

gemspec = Gem::Specification.load('metaclean.gemspec')
gem_file = "metaclean-#{gemspec.version}.gem"
gem_path = File.join('pkg', gem_file)

CLEAN.include('pkg/*.gem')
CLOBBER.include('pkg')

desc 'Build the metaclean gem into pkg/'
task :build do
  mkdir_p 'pkg'
  sh "gem build metaclean.gemspec --output #{gem_path.shellescape}"
end

desc 'Install the built gem into the current Ruby environment'
task install: :build do
  sh "gem install #{gem_path.shellescape}"
end

desc 'Push the built gem to RubyGems'
task release: :build do
  sh "gem push #{gem_path.shellescape}"
end

task default: :build
