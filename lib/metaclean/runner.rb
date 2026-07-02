# frozen_string_literal: true

module Metaclean
  class Runner
    def initialize(options)
      @options = options
      Display.configure(
        quiet: options.fetch(:quiet, false),
        redact_values: options.fetch(:redact_values, !$stdout.tty?)
      )
      @scan_errors = 0
      @path_guards = {}
      @discovery = Discovery.new(recursive: options.fetch(:recursive, false))
      @committer = Committer.new(
        in_place: options.fetch(:in_place, false),
        dry_run: options.fetch(:dry_run, false)
      )
    end

    def inspect_paths(paths)
      files = expand_files(paths)
      if files.empty?
        Display.warning('No files to inspect.')
        exit 1
      end
      failed = 0
      files.each do |file|
        Display.header "📄 #{file}"
        FileOps.ensure_path_guard!(file, guard_for(file))
        meta = Exiftool.read(file)
        Display.section "Metadata (#{Display.count_embedded(meta)} embedded tags)"
        Display.metadata_table(meta)
      rescue Error, SystemCallError => e
        warn Display.error("#{file}: #{e.message}")
        failed += 1
      end

      exit 1 if failed.positive? || @scan_errors.positive?
    end

    def clean_paths(paths)
      files = expand_files(paths)
      if files.empty?
        Display.warning('No files to process.')
        exit 1
      end

      announce_tools

      if @options[:in_place] && !@options[:dry_run]
        Display.warning 'Each backup is the ORIGINAL with all metadata intact; move or delete it before sharing.'
      end

      unless @options[:force] || @options[:dry_run]
        action = @options[:in_place] ? 'OVERWRITE' : 'create cleaned copies of'
        puts Display.c("About to #{action} #{files.size} file(s).", :yellow)
        print Display.c('Proceed? [y/N] ', :bold)
        ans = $stdin.gets&.strip&.downcase
        unless %w[y yes].include?(ans)
          Display.warning('Aborted.')
          exit 1
        end
      end

      summary = { cleaned: 0, unverified: 0, unsupported: 0, failed: 0, removed_total: 0, residual_files: 0 }

      files.each_with_index do |file, idx|
        tally(summary, clean_one(file, index: idx + 1, total: files.size))
      rescue Error, SystemCallError => e
        warn Display.error("#{file}: #{e.message}")
        summary[:failed] += 1
      end

      print_summary(summary)

      if summary[:failed].positive? || summary[:unverified].positive? ||
         summary[:unsupported].positive? || @scan_errors.positive?
        exit 1
      end
    end

    private

    def tally(summary, result)
      summary[result[:status]] += 1
      summary[:removed_total]  += result[:removed].to_i if result[:status] == :cleaned
      summary[:residual_files] += 1 if result[:residual].to_i.positive?
    end

    def announce_tools
      have = []
      have << "exiftool #{Exiftool.version}" if Exiftool.available?
      have << "mat2 #{Mat2.version}"         if Mat2.available?
      have << "qpdf #{Qpdf.version}"         if Qpdf.available?
      have << "ffmpeg #{Ffmpeg.version}"     if Ffmpeg.available?
      Display.info "Tools detected: #{have.join(', ')}"
      Display.info '(dry-run — no files will be modified)' if @options[:dry_run]
    end

    def clean_one(file, index:, total:)
      prefix = total > 1 ? "[#{index}/#{total}] " : ''
      Display.header "#{prefix}📄 #{file}"
      path_guard = guard_for(file)
      FileOps.ensure_path_guard!(file, path_guard)

      before = inspect_before(file)
      tools = selected_tools(file)
      final_path = resolve_final_path(file)
      staging    = staging_path_for(final_path)

      begin
        FileOps.ensure_path_guard!(file, path_guard)
        source_stat = copy_file_exclusive(file, staging)
        tool_results = tools.map { |tool| run_tool(tool, staging) }
        after = inspect_after(staging, before)
        residual = report_residual(after)
        result = finalize_result(tool_results, before, after, residual, file: file)
        return result if discard_result?(result)

        commit_cleaned(file, staging, final_path, source_stat, path_guard)
        result
      ensure
        cleanup_staging(staging)
      end
    end

    def inspect_before(file)
      metadata = read_metadata(file)
      Display.section "Before (#{Display.count_embedded(metadata)} embedded tags)"
      Display.metadata_table(metadata, only_embedded: true)
      metadata
    end

    def selected_tools(file)
      tools = Strategy.tools_for(file)
      if Strategy.mat2_essential?(file) && !tools.include?(:mat2)
        Display.warning 'mat2 will not run for this format — document-internal metadata may remain and cannot be verified.'
      end
      Display.info "Pipeline: #{tools.join(' → ')}"
      tools
    end

    def inspect_after(staging, before)
      metadata = read_metadata(staging)
      Display.section "After (#{Display.count_embedded(metadata)} embedded tags)"
      Display.metadata_table(metadata, only_embedded: true)
      Display.section 'Diff'
      Display.diff(before, metadata)
      metadata
    end

    def report_residual(metadata)
      residual = Strategy.privacy_residual(
        metadata,
        allow_icc_metadata: @options.fetch(:allow_icc_metadata, false)
      )
      return residual if residual.empty?

      Display.warning "Privacy-relevant tags still present (#{residual.size}):"
      unless Display.quiet?
        residual.each do |key, value|
          warn "    #{Display.c(key, :yellow)} = #{Display.truncate(Display.visible_value(value), 60)}"
        end
      end
      if residual.keys.all? { |key| key.to_s.start_with?('ICC') }
        Display.warning 'Only ICC profile text remains — review it and pass --allow-icc-metadata to accept it.'
      end
      residual
    end

    def discard_result?(result)
      if @options[:dry_run]
        Display.info '(dry-run: temporary copy removed; no output was kept)'
        return true
      end
      return false if result[:status] == :cleaned

      reason = case result[:status]
               when :unsupported then 'No cleaning tool supports this format'
               when :unverified then 'The complete cleaning pipeline could not be verified'
               else 'Privacy-relevant metadata survived or all tools failed'
               end
      Display.warning "#{reason} — not writing output."
      true
    end

    def commit_cleaned(file, staging, final_path, source_stat, path_guard)
      FileOps.ensure_same_file!(file, source_stat)
      FileOps.ensure_path_guard!(file, path_guard)
      if @options[:in_place]
        FileOps.prepare_in_place_commit!(staging, file, source_stat)
        warn_if_hardlinked(file)
      else
        FileOps.restore_metadata(staging, source_stat)
      end

      committed = commit!(staging, final_path, source_stat: source_stat)
      Display.success "→ #{committed[:path]}"
      Display.warning "Backup with original metadata: #{committed[:backup]}" if committed[:backup]
    end

    def warn_if_hardlinked(file)
      nlink = File.stat(file).nlink
      return unless nlink > 1

      Display.warning "#{file} has #{nlink} hard links — only this name is cleaned; " \
                      "the other #{nlink - 1} still contain the original metadata."
    end

    def run_tool(tool, path)
      case tool
      when :exiftool
        if Exiftool.strip!(path, also_delete: Strategy::PRIVACY_TAGS) == :unsupported
          Display.info '  · exiftool (read-only for this format, skipped)'
          { tool: :exiftool, ok: false, skipped: true, note: :unsupported }
        else
          Display.info '  ✓ exiftool'
          { tool: :exiftool, ok: true }
        end
      when :mat2
        result = Mat2.strip!(path)
        case result
        when :unsupported
          Display.info '  · mat2 (unsupported file type, skipped)'
          { tool: :mat2, ok: false, skipped: true, note: result }
        when :no_metadata
          Display.info '  · mat2 (no metadata to strip)'
          { tool: :mat2, ok: true, note: result }
        else
          Display.info '  ✓ mat2'
          { tool: :mat2, ok: true, note: result }
        end
      when :qpdf
        Qpdf.rebuild!(path)
        Display.info '  ✓ qpdf'
        { tool: :qpdf, ok: true }
      when :ffmpeg
        Ffmpeg.strip!(path)
        Display.info '  ✓ ffmpeg'
        { tool: :ffmpeg, ok: true }
      end
    rescue Error, SystemCallError => e
      msg = Display.truncate(e.message.gsub(/\s+/, ' ').strip, 200)
      Display.warning "  ✗ #{tool}: #{msg} — continuing"
      { tool: tool, ok: false, error: e.message }
    end

    def finalize_result(tool_results, before, after, residual, file: nil)
      removed = removed_embedded_count(before, after)
      status = if !tools_succeeded?(tool_results)
                 tool_errored?(tool_results) || residual.any? ? :failed : :unsupported
               elsif !residual.empty?
                 :failed
               elsif !tool_errored?(tool_results) && !mat2_coverage_gap?(tool_results, file)
                 :cleaned
               else
                 :unverified
               end
      { status: status, removed: removed, residual: residual.size }
    end

    def mat2_coverage_gap?(tool_results, file)
      return false unless file && Strategy.mat2_essential?(file)

      tool_results.none? { |r| r[:tool] == :mat2 && r[:ok] && !r[:skipped] }
    end

    def tools_succeeded?(tool_results)
      tool_results.any? { |r| r[:ok] && !r[:skipped] }
    end

    def tool_errored?(tool_results)
      tool_results.any? { |r| !r[:ok] && !r[:skipped] }
    end

    def read_metadata(path)
      Exiftool.read(path)
    end

    def removed_embedded_count(before, after)
      before.keys.count { |key| Display.embedded_key?(key) && !after.key?(key) }
    end

    def commit!(...) = @committer.commit!(...)
    def resolve_final_path(...) = @committer.resolve_final_path(...)
    def staging_path_for(...) = @committer.staging_path_for(...)
    def cleanup_staging(...) = @committer.cleanup_staging(...)
    def build_clean_path(...) = @committer.build_clean_path(...)
    def collision_safe(...) = @committer.collision_safe(...)
    def copy_file_exclusive(...) = @committer.copy_file_exclusive(...)
    def link_with_collision_safe_name(...) = @committer.link_with_collision_safe_name(...)

    def print_summary(summary)
      Display.header 'Summary'
      Display.success "Cleaned: #{summary[:cleaned]} file(s)"
      if summary[:unverified].positive?
        Display.warning "Unverified (clean could not be confirmed): #{summary[:unverified]} file(s)"
      end
      if summary[:unsupported].positive?
        Display.warning "Unsupported (not cleaned): #{summary[:unsupported]} file(s)"
      end
      warn Display.error("Failed:  #{summary[:failed]}") if summary[:failed].positive?
      Display.info "Total embedded tags removed: #{summary[:removed_total]}"
      if summary[:residual_files].positive?
        Display.warning "Files with privacy residual: #{summary[:residual_files]}"
      end
      if @scan_errors.positive?
        Display.warning "Paths skipped during discovery (not found or unreadable): #{@scan_errors}"
      end
    end

    def expand_files(paths)
      files = @discovery.expand(paths)
      @scan_errors = @discovery.scan_errors
      @path_guards = @discovery.guards
      files
    end

    def guard_for(file)
      @path_guards[file] || FileOps.path_guard!(file)
    end
  end
end
