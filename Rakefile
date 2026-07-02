# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.test_files = FileList['test/**/test_*.rb']
  t.warning = false
end

begin
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new
rescue LoadError
  nil
end

task default: %i[test build]
