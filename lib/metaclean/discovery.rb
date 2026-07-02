# frozen_string_literal: true

module Metaclean
  class Discovery
    attr_reader :scan_errors, :guards

    def initialize(recursive: false)
      @recursive = recursive
      @scan_errors = 0
      @guards = {}
    end

    def expand(paths)
      @scan_errors = 0
      @guards = {}
      explicit = []
      discovered = []
      paths.each do |path|
        collect_path(path, explicit, discovered)
      end
      discovered.reject! { |file| skip?(file) }
      result = dedupe_by_realpath(explicit + discovered)
      result.select do |file|
        @guards[file] = FileOps.path_guard!(file)
        true
      rescue Error, SystemCallError => e
        scan_failed(file, e)
        false
      end
    end

    def skip?(file)
      base = File.basename(file)
      base.start_with?('.') ||
        base.end_with?('.bak') ||
        base.match?(Metaclean::CLEAN_OUTPUT_RE) ||
        base.include?(Metaclean::TMP_MARKER)
    end

    def dedupe_by_realpath(paths)
      seen = {}
      paths.each_with_object([]) do |path, result|
        key = safe_realpath(path)
        next if seen[key]

        seen[key] = true
        result << path
      end
    end

    private

    def collect_path(path, explicit, discovered)
      unless File.exist?(path) || File.symlink?(path)
        Display.warning "Not found: #{path}"
        @scan_errors += 1
        return
      end

      FileOps.path_guard!(path)
      if File.directory?(path)
        collect_dir(path, discovered)
      elsif File.file?(path)
        explicit << path
      else
        scan_failed(path, Error.new('not a regular file or directory'))
      end
    rescue Error, SystemCallError => e
      scan_failed(path, e)
    end

    def safe_realpath(path)
      File.realpath(path)
    rescue SystemCallError
      path
    end

    def collect_dir(dir, files)
      if @recursive
        walk_recursive(dir, files)
      else
        Dir.children(dir).each do |entry|
          next if entry.start_with?('.')

          path = File.join(dir, entry)
          next if File.symlink?(path)

          begin
            FileOps.path_guard!(path)
            files << path if File.file?(path)
          rescue Error, SystemCallError => e
            scan_failed(path, e)
          end
        end
      end
    rescue SystemCallError => e
      scan_failed(dir, e)
    end

    def walk_recursive(dir, files)
      Dir.each_child(dir) do |entry|
        next if entry.start_with?('.')

        path = File.join(dir, entry)
        next if File.symlink?(path)

        begin
          FileOps.path_guard!(path)
          if File.directory?(path)
            walk_recursive(path, files)
          elsif File.file?(path)
            files << path
          end
        rescue Error, SystemCallError => e
          scan_failed(path, e)
        end
      end
    rescue SystemCallError => e
      scan_failed(dir, e)
    end

    def scan_failed(dir, error)
      Display.warning "Skipping #{dir}: #{error.message}"
      @scan_errors += 1
    end
  end
end
