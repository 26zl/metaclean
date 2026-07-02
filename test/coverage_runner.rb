# frozen_string_literal: true

require 'coverage'

Coverage.start(lines: true, branches: true)
Dir[File.expand_path('test_*.rb', __dir__)].each do |file|
  require file unless file.end_with?('/test_helper.rb')
end

Minitest.after_run do
  result = Coverage.result.select { |path, _| path.include?('/lib/metaclean') }
  executable = result.sum { |_path, data| data[:lines].count { |count| !count.nil? } }
  line_hits = result.sum { |_path, data| data[:lines].count { |count| count&.positive? } }
  branch_counts = result.flat_map { |_path, data| data[:branches].values.flat_map(&:values) }
  branch_hits = branch_counts.count(&:positive?)
  line_rate = 100.0 * line_hits / executable
  branch_rate = 100.0 * branch_hits / branch_counts.size

  puts format('Coverage: lines %.1f%% (%d/%d), branches %.1f%% (%d/%d)',
              line_rate, line_hits, executable, branch_rate, branch_hits, branch_counts.size)
  raise "Coverage below required floor (lines 90%, branches 70%)" if line_rate < 90 || branch_rate < 70
end
