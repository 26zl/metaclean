# frozen_string_literal: true

# ───────────────────────────────────────────────────────────────────────────
# The orchestrator. Given a list of paths and parsed CLI options, this class:
#
#   1. Expands paths into a flat list of files (handling directories,
#      recursion, symlinks, type filters).
#   2. Asks the user for confirmation (unless --force).
#   3. For each file, runs the strategy pipeline (mat2 / exiftool / qpdf)
#      using the "atomic write" pattern so a crash never leaves a
#      half-cleaned file.
#   4. Prints a before/after diff and a final summary.
# ───────────────────────────────────────────────────────────────────────────

require 'fileutils'
require 'json'
require 'set'
require 'tmpdir'

module Metaclean
  class Runner
    # Constructor — just stashes the options Hash. The CLI builds it.
    def initialize(options)
      @options = options
    end

    # ─────────────────────────────────────────────────────────────────
    # Public entry points: one for `--inspect`, one for the cleaning flow.
    # ─────────────────────────────────────────────────────────────────

    def inspect_paths(paths)
      files = expand_files(paths)
      return Display.warning('No files to inspect.') if files.empty?

      # `--json`: machine output, no colors, suitable for piping.
      if @options[:format] == :json
        out = files.map { |f| { file: f, metadata: Exiftool.read(f) } }
        puts JSON.pretty_generate(out)
        return
      end

      # Human output: pretty header + grouped table per file.
      files.each do |file|
        Display.header "📄 #{file}"
        meta = Exiftool.read(file)
        Display.section "Metadata (#{Display.count_embedded(meta)} embedded tags)"
        Display.metadata_table(meta)
      end
    end

    def clean_paths(paths)
      files = expand_files(paths)
      return Display.warning('No files to process.') if files.empty?

      announce_tools

      # Confirmation prompt — skipped for --force and --dry-run (since
      # dry-run never modifies anything anyway).
      unless @options[:force] || @options[:dry_run]
        action = @options[:in_place] ? 'OVERWRITE' : 'create cleaned copies of'
        puts Display.c("About to #{action} #{files.size} file(s).", :yellow)
        if @options[:in_place] && !@options[:no_backup]
          puts Display.c('Backups will be saved alongside as <file>.bak.', :gray)
        end
        print Display.c('Proceed? [y/N] ', :bold)
        # `&.` is the safe-navigation operator: if `gets` returns nil
        # (e.g. user hit Ctrl-D), the chain short-circuits to nil.
        ans = $stdin.gets&.strip&.downcase
        return Display.warning('Aborted.') unless %w[y yes].include?(ans)
      end

      summary = { cleaned: 0, failed: 0, removed_total: 0, residual_files: 0 }

      # `each_with_index` gives us the file AND its position. We pass both
      # to `clean_one` so it can render "[3/47]" in batch mode.
      files.each_with_index do |file, idx|
        result = clean_one(file, index: idx + 1, total: files.size)
        summary[result[:status]] += 1
        summary[:removed_total]  += result[:removed].to_i
        summary[:residual_files] += 1 if result[:residual].to_i.positive?
      rescue Error => e
        # Block-level rescue (Ruby 2.5+). Catches errors from `clean_one`
        # without aborting the whole batch — one bad file shouldn't stop
        # the next 99 from being cleaned.
        warn Display.error("#{file}: #{e.message}")
        summary[:failed] += 1
      end

      print_summary(summary)

      # Non-zero exit code so CI pipelines can detect failures.
      exit 1 if @options[:strict_verify] && summary[:residual_files].positive?
      exit 1 if summary[:failed].positive?
    end

    private

    # ─────────────────────────────────────────────────────────────────
    # Output helpers
    # ─────────────────────────────────────────────────────────────────

    def announce_tools
      have = []
      have << "exiftool #{Exiftool.version}"     if Exiftool.available?
      have << "mat2 #{Mat2.version}"             if Mat2.available?
      have << "qpdf #{Qpdf.version&.split&.last}" if Qpdf.available?
      Display.info "Tools detected: #{have.join(', ')}"
      Display.info '(dry-run — no files will be modified)' if @options[:dry_run]
    end

    # ─────────────────────────────────────────────────────────────────
    # Cleaning a single file — the heart of the program.
    # ─────────────────────────────────────────────────────────────────

    def clean_one(file, index:, total:)
      prefix = total > 1 ? "[#{index}/#{total}] " : ''
      Display.header "#{prefix}📄 #{file}"

      # Read the "before" metadata FIRST — once we start cleaning, this is
      # gone forever and we'd have nothing to diff against.
      before = Exiftool.read(file)
      Display.section "Before (#{Display.count_embedded(before)} embedded tags)"
      Display.metadata_table(before, only_embedded: true)

      # Ask the strategy module which tools to run. If everything's
      # disabled (user passed all --no-* flags), bail out gracefully.
      tools = Strategy.tools_for(file, prefer: tool_prefs)
      if tools.empty?
        Display.warning 'No applicable tools — skipping.'
        return { status: :failed, removed: 0, residual: 0 }
      end
      Display.info "Pipeline: #{tools.join(' → ')}"

      # ── Atomic write setup ────────────────────────────────────────
      # `final_path` = where the cleaned file will end up.
      # `staging`    = a temp file we mutate. After all tools succeed, we
      #                rename staging → final_path. If anything goes wrong
      #                in the middle, we delete staging in the `ensure`
      #                block and the original is untouched.
      final_path = resolve_final_path(file)
      staging    = staging_path_for(final_path)

      FileUtils.cp(file, staging)
      tool_results = []
      begin
        tools.each do |tool|
          tool_results << run_tool(tool, staging)
        end

        # Re-read metadata of the cleaned staging file for the diff.
        after = Exiftool.read(staging)
        Display.section "After (#{Display.count_embedded(after)} embedded tags)"
        Display.metadata_table(after, only_embedded: true)

        Display.section 'Diff'
        Display.diff(before, after)

        # Loud warning if anything privacy-relevant survived.
        residual = Strategy.privacy_residual(after)
        if residual.any?
          Display.warning "Privacy-relevant tags still present (#{residual.size}):"
          residual.each { |k, v| puts "    #{Display.c(k, :yellow)} = #{Display.truncate(Display.format_value(v), 60)}" }
        end

        # Dry-run path: discard the staging file and return without committing.
        if @options[:dry_run]
          File.delete(staging) if File.exist?(staging)
          Display.info '(dry-run: nothing was written)'
          return finalize_result(tool_results, before, after, residual)
        end

        # Commit: rename staging → final_path (and back up original if needed).
        commit!(file, staging, final_path)
        Display.success "→ #{final_path}"

        finalize_result(tool_results, before, after, residual)
      ensure
        # Last-resort cleanup. If `commit!` already moved the staging file,
        # `File.exist?(staging)` is false and this is a no-op. The path-
        # comparison protects against deleting the final file by accident
        # in the (impossible) case where staging == final.
        File.delete(staging) if File.exist?(staging) && File.expand_path(staging) != File.expand_path(final_path)
      end
    end

    # Dispatches to the right wrapper module. Returns a small Hash so the
    # caller can summarize tool-by-tool success/failure.
    def run_tool(tool, path)
      case tool
      when :exiftool
        Exiftool.strip!(path,
                        keep_orientation:   @options[:keep_orientation],
                        keep_color_profile: @options[:keep_color_profile])
        Display.info "  ✓ exiftool"
        { tool: :exiftool, ok: true }
      when :mat2
        result = Mat2.strip!(path)
        # mat2 returns either `true` (success) or a symbol indicating a
        # soft skip. `:unsupported` means the tool didn't actually run, so
        # it must not count as a successful pass — otherwise a file can be
        # reported as "Cleaned" while metadata is still embedded.
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
      end
    rescue Error => e
      # One tool failing shouldn't abort the pipeline — we want to keep
      # trying with the others. The `finalize_result` step decides whether
      # the overall file counts as cleaned or failed.
      Display.warning "  ✗ #{tool}: #{e.message} — continuing"
      { tool: tool, ok: false, error: e.message }
    end

    def finalize_result(tool_results, before, after, residual)
      removed = removed_embedded_count(before, after)
      # A file only counts as "cleaned" if at least one tool actually ran
      # successfully (i.e. wasn't skipped as unsupported) AND no privacy-
      # relevant tags survived. Anything else is a failure — silently
      # marking a file clean when sensitive metadata is still present is
      # the worst possible outcome for a privacy tool.
      ran_ok = tool_results.any? { |r| r[:ok] && !r[:skipped] }
      status = ran_ok && residual.empty? ? :cleaned : :failed
      { status: status,
        removed: removed,
        residual: residual.size,
        tools: tool_results }
    end

    def removed_embedded_count(before, after)
      after_keys = after.keys.to_set
      before.keys.count do |key|
        next false if key == 'SourceFile'
        next false if Display::NON_METADATA_GROUPS.include?(Display.group_of(key))

        !after_keys.include?(key)
      end
    end

    # ─────────────────────────────────────────────────────────────────
    # Path helpers — figuring out where to stage and where to commit.
    # ─────────────────────────────────────────────────────────────────

    def commit!(source, staging, final_path)
      # Make a backup of the original BEFORE we overwrite it. The order
      # matters: if the rename below fails, the backup still exists.
      # When source is a symlink, place the backup next to the *target*
      # (which is what --in-place actually overwrites) — putting the .bak
      # next to the link is confusing during recovery.
      if @options[:in_place] && !@options[:no_backup]
        backup_target = File.symlink?(source) ? File.realpath(source) : source
        backup = collision_safe("#{backup_target}.bak")
        FileUtils.cp(backup_target, backup)
      end
      FileUtils.mv(staging, final_path)
    end

    def resolve_final_path(file)
      # When following a symlink with --in-place, we want to overwrite the
      # *target* of the link, not replace the link itself with a regular
      # file. `realpath` resolves through the link.
      return File.realpath(file) if @options[:in_place] && File.symlink?(file)
      return file if @options[:in_place]

      # Default: write `<name>_clean.<ext>` next to the original. If it
      # already exists, `collision_safe` appends `_1`, `_2`, …
      collision_safe(build_clean_path(file))
    end

    def build_clean_path(file)
      ext  = File.extname(file)
      base = File.basename(file, ext)
      File.join(File.dirname(file), "#{base}_clean#{ext}")
    end

    # Staging path lives in the same directory as the destination so that
    # `File.rename`/`FileUtils.mv` is an atomic same-filesystem operation.
    # PID + random number prevent collisions between simultaneous runs.
    # The original extension is preserved as the LAST segment so tools like
    # mat2 — which dispatch on file extension — see the real type.
    def staging_path_for(final_path)
      ext  = File.extname(final_path)
      base = ext.empty? ? final_path : final_path[0...-ext.length]
      "#{base}.metaclean.tmp.#{Process.pid}.#{rand(1_000_000)}#{ext}"
    end

    # If `path` is taken, return `path_1`, `path_2`, … until we find a free
    # one. `loop do … end` runs forever; we `return` out of it.
    def collision_safe(path)
      return path unless File.exist?(path)

      ext  = File.extname(path)
      base = File.basename(path, ext)
      dir  = File.dirname(path)
      i = 1
      loop do
        candidate = File.join(dir, "#{base}_#{i}#{ext}")
        return candidate unless File.exist?(candidate)

        i += 1
      end
    end

    # Translates the on/off CLI flags into a "prefer" hash that Strategy
    # understands. Keeping this as one method makes the wiring obvious.
    def tool_prefs
      {
        mat2:     !@options[:no_mat2]     && !@options[:exiftool_only],
        qpdf:     !@options[:no_qpdf]     && !@options[:exiftool_only],
        exiftool: !@options[:no_exiftool]
      }
    end

    def print_summary(summary)
      Display.header 'Summary'
      Display.success "Cleaned: #{summary[:cleaned]} file(s)"
      puts Display.error("Failed:  #{summary[:failed]}") if summary[:failed].positive?
      Display.info "Total embedded tags removed: #{summary[:removed_total]}"
      if summary[:residual_files].positive?
        Display.warning "Files with privacy residual: #{summary[:residual_files]}"
      end
    end

    # ─────────────────────────────────────────────────────────────────
    # File discovery — turning the user's paths into a flat list.
    # ─────────────────────────────────────────────────────────────────

    def expand_files(paths)
      explicit   = []
      discovered = []
      paths.each do |p|
        # Symlinks are skipped by default. This avoids accidentally cleaning
        # something through a link that points outside the intended scope.
        if File.symlink?(p) && !@options[:follow_symlinks]
          Display.warning "Skipping symlink: #{p} (use --follow-symlinks to include)"
          next
        end
        if File.directory?(p)
          collect_dir(p, discovered)
        elsif File.file?(p)
          # Explicit file argument — never apply skip?, the user asked for
          # this exact path. (Skip filters exist to avoid re-cleaning our
          # own outputs during recursion, not to override the CLI.)
          explicit << p
        else
          Display.warning "Not found: #{p}"
        end
      end
      discovered.reject! { |f| skip?(f) }
      result = explicit + discovered
      result.select! { |f| type_allowed?(f) } if @options[:types]
      dedupe_by_realpath(result)
    end

    # Same file via two different paths (or via symlink + direct path) should
    # be cleaned once. Comparing by realpath catches both cases. If realpath
    # raises (broken symlink, permission denied), fall back to the raw path.
    def dedupe_by_realpath(paths)
      seen = {}
      paths.each_with_object([]) do |p, acc|
        key = begin
                File.realpath(p)
              rescue StandardError
                p
              end
        next if seen[key]

        seen[key] = true
        acc << p
      end
    end

    def collect_dir(dir, out)
      if @options[:recursive]
        walk_recursive(dir, out, Set.new)
      else
        # Non-recursive: just the immediate children of `dir`.
        Dir.glob(File.join(dir, '*')).each do |sub|
          next if File.symlink?(sub) && !@options[:follow_symlinks]

          out << sub if File.file?(sub)
        end
      end
    end

    # Manual recursive walker. We don't use `Find.find` because it never
    # descends into symlinked directories, even when --follow-symlinks is on.
    # `visited` tracks realpaths so we don't infinite-loop on a symlink that
    # eventually points at one of its ancestors.
    def walk_recursive(dir, out, visited)
      real = begin
               File.realpath(dir)
             rescue StandardError
               dir
             end
      return if visited.include?(real)

      visited << real

      Dir.each_child(dir) do |entry|
        sub = File.join(dir, entry)
        if File.symlink?(sub)
          next unless @options[:follow_symlinks]

          if File.directory?(sub)
            walk_recursive(sub, out, visited)
          elsif File.file?(sub)
            out << sub
          end
        elsif File.directory?(sub)
          walk_recursive(sub, out, visited)
        elsif File.file?(sub)
          out << sub
        end
      end
    rescue Errno::EACCES, Errno::ENOENT => e
      Display.warning "Skipping #{dir}: #{e.message}"
    end

    # Files we never touch when DISCOVERED via directory scanning. This is
    # NOT applied to explicit CLI arguments — if the user typed
    # `metaclean .hidden.jpg`, they meant it. Hidden files (dot-prefixed)
    # might be system metadata; .bak/_clean/.metaclean.tmp.* are our own
    # outputs, so skipping them prevents loops on re-runs.
    def skip?(file)
      base = File.basename(file)
      return true if base.start_with?('.')
      return true if base.end_with?('.bak')
      return true if base =~ /_clean(_\d+)?\.[^.]+\z/
      return true if base =~ /\.metaclean\.tmp\.\d+\.\d+/

      false
    end

    def type_allowed?(file)
      ext = File.extname(file).downcase.delete('.')
      @options[:types].include?(ext)
    end
  end
end
