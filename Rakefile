# frozen_string_literal: true

# `bundler/gem_tasks` defines the standard build / install / release tasks
# from the gemspec. We use these instead of a hand-rolled `gem push` so that
# `rubygems/release-gem` (the Trusted Publisher action) drives the supported
# `rake release` flow — including its working-tree and version/tag guards —
# rather than a bespoke push that can publish the wrong artifact.
require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.test_files = FileList['test/**/test_*.rb']
  t.warning = false
end

# Lint is optional: only define the task if rubocop is installed.
begin
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new
rescue LoadError
  nil
end

task default: %i[test build]
