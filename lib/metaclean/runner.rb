# frozen_string_literal: true

# The orchestrator. Given a list of paths and parsed CLI options, this class:
#
#   1. Expands paths into a flat list of files (handling directories and
#      recursion; symlinks are skipped).
#   2. Asks the user for confirmation (unless --force).
#   3. For each file, runs the strategy pipeline (mat2 / exiftool / qpdf)
#      using the "atomic write" pattern so a crash never leaves a
#      half-cleaned file.
#   4. Prints a before/after diff and a final summary.

require 'fileutils'
require 'securerandom'

module Metaclean
  class Runner
    def initialize(options)
      @options = options
      # Paths that couldn't be read during discovery (missing arg, unreadable
      # directory). Tracked so a partially-scanned batch exits non-zero instead
      # of letting automation mistake "some files cleaned" for "everything done".
      @scan_errors = 0
    end

    # Public entry points: one for `--inspect`, one for the cleaning flow.

    def inspect_paths(paths)
      files = expand_files(paths)
      if files.empty?
        Display.warning('No files to inspect.')
        exit 1
      end
      failed = 0
      files.each do |file|
        Display.header "📄 #{file}"
        meta = Exiftool.read(file)
        Display.section "Metadata (#{Display.count_embedded(meta)} embedded tags)"
        Display.metadata_table(meta)
      rescue Error, SystemCallError => e
        # One unreadable/odd file shouldn't abort inspecting the rest — mirrors
        # the per-file rescue in the clean batch.
        warn Display.error("#{file}: #{e.message}")
        failed += 1
      end

      # A file we couldn't read is a non-zero condition: a script using --inspect
      # as a gate must not mistake "couldn't read it" for "no metadata". Discovery
      # errors (missing paths / unreadable dirs) count too.
      exit 1 if failed.positive? || @scan_errors.positive?
    end

    def clean_paths(paths)
      files = expand_files(paths)
      # See inspect_paths: nothing to act on is a non-zero condition, not success.
      if files.empty?
        Display.warning('No files to process.')
        exit 1
      end

      announce_tools

      # Confirmation prompt — skipped for --force and --dry-run (since
      # dry-run never modifies anything anyway).
      unless @options[:force] || @options[:dry_run]
        action = @options[:in_place] ? 'OVERWRITE' : 'create cleaned copies of'
        puts Display.c("About to #{action} #{files.size} file(s).", :yellow)
        if @options[:in_place]
          # The .bak IS the original — metadata intact. Say so plainly: a user who
          # shares the "cleaned" folder would otherwise leak it via the backup.
          puts Display.c('Each <file>.bak is the ORIGINAL, with all metadata still in it — ' \
                         'delete or move the .bak files before sharing the folder.', :yellow)
        end
        print Display.c('Proceed? [y/N] ', :bold)
        ans = $stdin.gets&.strip&.downcase # gets → nil on Ctrl-D
        # Abort (no/blank/EOF) is a non-zero exit, not silent success — a
        # non-interactive caller must not read "Aborted." as "files were cleaned".
        unless %w[y yes].include?(ans)
          Display.warning('Aborted.')
          exit 1
        end
      end

      summary = { cleaned: 0, unverified: 0, failed: 0, removed_total: 0, residual_files: 0 }

      # index/total let clean_one render "[3/47]" in batch mode.
      files.each_with_index do |file, idx|
        result = clean_one(file, index: idx + 1, total: files.size)
        summary[result[:status]] += 1
        summary[:removed_total]  += result[:removed].to_i
        summary[:residual_files] += 1 if result[:residual].to_i.positive?
      rescue Error, SystemCallError => e
        # One bad file shouldn't abort the whole batch. SystemCallError
        # (Errno::*: disk full, permission denied, read-only fs) is a SIBLING
        # of our Error, not a subclass, so it must be named explicitly or it
        # would escape this rescue and crash the run with a raw backtrace.
        warn Display.error("#{file}: #{e.message}")
        summary[:failed] += 1
      end

      print_summary(summary)

      # Non-zero exit so CI/scripts can detect a failed or not-fully-verified file,
      # OR a batch that was never fully discovered (a path/dir we couldn't read).
      exit 1 if summary[:failed].positive? || summary[:unverified].positive? || @scan_errors.positive?
    end

    private

    # Output helpers

    def announce_tools
      have = []
      have << "exiftool #{Exiftool.version}" if Exiftool.available?
      have << "mat2 #{Mat2.version}"         if Mat2.available?
      have << "qpdf #{Qpdf.version}"         if Qpdf.available?
      have << "ffmpeg #{Ffmpeg.version}"     if Ffmpeg.available?
      Display.info "Tools detected: #{have.join(', ')}"
      Display.info '(dry-run — no files will be modified)' if @options[:dry_run]
    end

    # Cleaning a single file.
    def clean_one(file, index:, total:)
      prefix = total > 1 ? "[#{index}/#{total}] " : ''
      Display.header "#{prefix}📄 #{file}"

      # Read the "before" metadata FIRST — once we start cleaning, this is
      # gone forever and we'd have nothing to diff against.
      before = read_metadata(file)
      Display.section "Before (#{Display.count_embedded(before)} embedded tags)"
      Display.metadata_table(before, only_embedded: true)

      # Ask the strategy module which tools to run for this file type.
      tools = Strategy.tools_for(file)
      # Warn when the stricter tool for a document format won't run: ExifTool
      # alone leaves (and can't fully verify) document-internal metadata.
      if Strategy.mat2_essential?(file) && !tools.include?(:mat2)
        Display.warning 'mat2 will not run for this format — document-internal metadata may remain and cannot be verified.'
      end
      Display.info "Pipeline: #{tools.join(' → ')}"

      # Atomic write setup:
      # `final_path` = where the cleaned file will end up.
      # `staging`    = a temp file we mutate. After all tools succeed, we
      #                rename staging → final_path. If anything goes wrong
      #                in the middle, we delete staging in the `ensure`
      #                block and the original is untouched.
      final_path = resolve_final_path(file)
      staging    = staging_path_for(final_path)

      tool_results = []
      begin
        # TOCTOU guard: the path was a regular file at discovery (expand_files), but
        # it could have been swapped for a symlink in the window since. Re-check
        # right before we read/copy/back it up, so we never copy — or take a .bak —
        # THROUGH a link pointing outside the intended scope. Bails to :failed.
        raise Error, "#{file} became a symlink since discovery — refusing to clean it" if File.symlink?(file)

        # The staging copy lives INSIDE the begin so the ensure below cleans up a
        # partial temp if cp is interrupted (Ctrl-C) or fails mid-copy (disk full,
        # read-only fs). cp only ever reads the original, so the source is intact
        # regardless.
        copy_file_exclusive(file, staging)
        tools.each do |tool|
          tool_results << run_tool(tool, staging)
        end

        # Re-read metadata of the cleaned staging file for the diff.
        after = read_metadata(staging)
        Display.section "After (#{Display.count_embedded(after)} embedded tags)"
        Display.metadata_table(after, only_embedded: true)

        Display.section 'Diff'
        Display.diff(before, after)

        # Anything privacy-relevant that survived the strip.
        residual = Strategy.privacy_residual(after)
        if residual.any?
          Display.warning "Privacy-relevant tags still present (#{residual.size}):"
          residual.each { |k, v| puts "    #{Display.c(k, :yellow)} = #{Display.truncate(Display.format_value(v), 60)}" }
        end

        # Dry-run path: discard the staging file and return without committing.
        if @options[:dry_run]
          File.delete(staging) if File.exist?(staging)
          Display.info '(dry-run: nothing was written)'
          return finalize_result(tool_results, before, after, residual, file: file)
        end

        # Never write output unless the file is genuinely clean: at least one
        # tool ran AND no privacy-relevant tag survived. Otherwise the staging
        # file — committed as a "_clean" copy or an in-place overwrite — would
        # not actually be clean, the exact false-clean this tool exists to
        # prevent. Bail to :failed and let the ensure block delete staging,
        # leaving the original untouched.
        unless cleaned?(tool_results, residual)
          reason = tools_succeeded?(tool_results) ? 'Privacy-relevant tags survived' : 'All tools failed'
          Display.warning "#{reason} — not writing output."
          return finalize_result(tool_results, before, after, residual, file: file)
        end

        # Preserve the original's permission bits onto the cleaned output. cp and
        # the tools' temp renames otherwise leave it at the umask default, which
        # could widen a locked-down 0600 file to 0644 — a leak for a privacy tool.
        File.chmod(File.stat(file).mode, staging)

        # In-place clean of a hard-linked file only re-points THIS name (rename) at
        # the freshly-cleaned inode; the file's other names still point at the
        # original, metadata-bearing inode. This name is genuinely clean, but warn
        # so the user knows the other links aren't covered by the run.
        warn_if_hardlinked(file) if @options[:in_place]

        # Commit: move/link staging → final_path (backing up the original in place).
        final_path = commit!(staging, final_path)
        result = finalize_result(tool_results, before, after, residual, file: file)
        if result[:status] == :unverified
          reason = tool_errored?(tool_results) ? 'a tool in the pipeline failed' : 'mat2 did not run on this format'
          Display.warning "→ #{final_path} (unverified — #{reason})"
        else
          Display.success "→ #{final_path}"
        end
        result
      ensure
        # Last-resort cleanup. If `commit!` already moved the staging file,
        # `File.exist?(staging)` is false and this is a no-op. The path-
        # comparison protects against deleting the final file by accident
        # in the (impossible) case where staging == final.
        File.delete(staging) if File.exist?(staging) && File.expand_path(staging) != File.expand_path(final_path)
      end
    end

    # Warn when an in-place target has more than one hard link: a rename only
    # cleans the named link, leaving the others pointing at the original metadata.
    def warn_if_hardlinked(file)
      nlink = File.stat(file).nlink
      return unless nlink > 1

      Display.warning "#{file} has #{nlink} hard links — only this name is cleaned; " \
                      "the other #{nlink - 1} still contain the original metadata."
    end

    # Dispatches to the right wrapper module. Returns a small Hash so the
    # caller can summarize tool-by-tool success/failure.
    def run_tool(tool, path)
      case tool
      when :exiftool
        # :unsupported means ExifTool can read but not write this format (a
        # ZIP-based document mat2 owns) — a soft skip, NOT a pipeline failure.
        # Pass the privacy tag names so TIFF/DNG IFD0 tags `-all=` won't drop
        # still get deleted (losslessly).
        if Exiftool.strip!(path, also_delete: Strategy::PRIVACY_TAGS) == :unsupported
          Display.info '  · exiftool (read-only for this format, skipped)'
          { tool: :exiftool, ok: false, skipped: true, note: :unsupported }
        else
          Display.info '  ✓ exiftool'
          { tool: :exiftool, ok: true }
        end
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
      when :ffmpeg
        # Matroska remux. A failure raises and is caught below (→ not written).
        Ffmpeg.strip!(path)
        Display.info '  ✓ ffmpeg'
        { tool: :ffmpeg, ok: true }
      end
    rescue Error, SystemCallError => e
      # One tool failing shouldn't abort the pipeline — we want to keep
      # trying with the others. The `finalize_result` step decides whether
      # the overall file counts as cleaned or failed. `SystemCallError`
      # (Errno::*) covers a tool wrapper's internal FileUtils.mv/File.delete
      # raising on permission/quota/disk errors — without it those would
      # escape and crash the batch.
      # Collapse whitespace and bound the length: some tools (notably mat2) dump a
      # multi-line Python traceback on failure, which would otherwise flood the
      # diff. One readable line is enough — re-run the tool directly to debug.
      msg = Display.truncate(e.message.gsub(/\s+/, ' ').strip, 200)
      Display.warning "  ✗ #{tool}: #{msg} — continuing"
      { tool: tool, ok: false, error: e.message }
    end

    # :cleaned needs ALL of: a tool genuinely ran, no privacy residual survived,
    # no pipeline tool errored, AND — for a format where mat2 owns coverage
    # ExifTool can't re-read (Office/PDF doc internals) — mat2 actually ran. A
    # tool that errored, or an absent mat2 on a document format, means the
    # pipeline didn't fully complete and the residual check is partly blind, so
    # the result is :unverified, not a confident :cleaned. `file` is needed only
    # for that mat2-coverage check.
    def finalize_result(tool_results, before, after, residual, file: nil)
      removed = removed_embedded_count(before, after)
      status = if !cleaned?(tool_results, residual)
                 :failed
               elsif !tool_errored?(tool_results) && !mat2_coverage_gap?(tool_results, file)
                 :cleaned
               else
                 :unverified
               end
      { status: status, removed: removed, residual: residual.size }
    end

    # mat2 is essential for this format (Office/PDF internals ExifTool can't
    # strip or fully re-read) but did NOT actually run and strip — absent,
    # unsupported soft-skip, or errored. The residual check can't confirm the
    # clean, so don't report a confident :cleaned.
    def mat2_coverage_gap?(tool_results, file)
      return false unless file && Strategy.mat2_essential?(file)

      tool_results.none? { |r| r[:tool] == :mat2 && r[:ok] && !r[:skipped] }
    end

    # A file is genuinely cleaned only when at least one tool actually ran
    # (not just a mat2 :unsupported soft-skip) AND no privacy-relevant tag
    # survived. Both the commit gate and the final status use this ONE
    # predicate, so they can never disagree — we never write a "_clean" copy
    # (or overwrite an original in place) and then report it :failed. Silently
    # marking a file clean while sensitive metadata is still present is the
    # worst possible outcome for a privacy tool.
    def cleaned?(tool_results, residual)
      tools_succeeded?(tool_results) && residual.empty?
    end

    # Did at least one tool genuinely run (not a mat2 :unsupported soft-skip)?
    def tools_succeeded?(tool_results)
      tool_results.any? { |r| r[:ok] && !r[:skipped] }
    end

    # Did a tool that was meant to run error out (not a mat2 :unsupported
    # soft-skip)? Even with an empty residual that means the pipeline didn't
    # fully complete, so the clean can't be reported as a confident :cleaned.
    def tool_errored?(tool_results)
      tool_results.any? { |r| !r[:ok] && !r[:skipped] }
    end

    # Read metadata for the before/after diff. ensure_tools! guarantees exiftool
    # is present before any run.
    def read_metadata(path)
      Exiftool.read(path)
    end

    def removed_embedded_count(before, after)
      before.keys.count { |key| Display.embedded_key?(key) && !after.key?(key) }
    end

    # Path helpers — figuring out where to stage and where to commit.

    def commit!(staging, final_path)
      committed = false
      # Make a backup of the original BEFORE we overwrite it. The order matters:
      # if the rename below fails, the backup still exists.
      if @options[:in_place]
        backup = copy_with_collision_safe_name(final_path, "#{final_path}.bak")
        # File.rename, NOT FileUtils.mv. staging is in the same dir as final_path
        # (staging_path_for), so this is always an atomic same-fs swap. FileUtils.mv
        # would, on EPERM (e.g. a sticky /tmp file not owned by us) or EXDEV, fall
        # back to a TRUNCATING copy of the original — and an interrupt mid-copy
        # would corrupt the original while the rescue below deleted the only backup.
        # File.rename raises BEFORE touching final_path, so the rescue's
        # "staging still exists ⇒ original intact" assumption always holds.
        File.rename(staging, final_path)
        committed = true
        return final_path
      end

      link_with_collision_safe_name(staging, final_path)
    rescue SystemCallError, Interrupt
      # The rename failed (disk full, read-only fs, cross-device) OR the user hit
      # Ctrl-C in the window after the .bak was written but before the mv. Either
      # way the original is untouched, so the .bak is a redundant copy of it —
      # remove it instead of leaving a stray file behind, then re-raise (a
      # SystemCallError is reported per-file as failed; an Interrupt propagates to
      # the CLI's exit-130 handler).
      File.delete(backup) if backup && !committed && File.exist?(staging) && File.exist?(backup)
      raise
    end

    def link_with_collision_safe_name(staging, preferred)
      target = preferred
      loop do
        File.link(staging, target)
        File.delete(staging)
        return target
      rescue Errno::EEXIST
        target = collision_safe(target)
      rescue Errno::EACCES, Errno::EPERM, Errno::ENOTSUP, NotImplementedError
        # The filesystem can't hard-link (Linux returns EPERM; macOS/BSD on
        # exFAT/FAT/SMB returns ENOTSUP/EOPNOTSUPP — same Errno class). Fall back
        # to a plain exclusive copy so removable/network drives still clean.
        target = copy_with_collision_safe_name(staging, target)
        File.delete(staging)
        return target
      end
    end

    def copy_with_collision_safe_name(src, preferred)
      target = preferred
      loop do
        copy_file_exclusive(src, target, preserve: true)
        return target
      rescue Errno::EEXIST
        target = collision_safe(target)
      end
    end

    def copy_file_exclusive(src, dest, preserve: false)
      src_stat = File.lstat(src)
      raise Error, "#{src} is a symlink — refusing to copy it" if src_stat.symlink?

      mode = src_stat.mode & 0o7777
      created = false
      File.open(dest, File::WRONLY | File::CREAT | File::EXCL, mode) do |out|
        created = true
        File.open(src, 'rb') do |input|
          opened = input.stat
          unless opened.dev == src_stat.dev && opened.ino == src_stat.ino
            raise Error, "#{src} changed while opening — refusing to copy it"
          end

          IO.copy_stream(input, out)
        end
      end
      return unless preserve

      # Best-effort: the bytes are already fully copied, so a failed mode/timestamp
      # restore (e.g. utime/chmod on a FAT/exFAT mount) must NOT discard an
      # otherwise-complete file by falling into the delete-on-error rescue below.
      begin
        File.chmod(mode, dest)
        File.utime(src_stat.atime, src_stat.mtime, dest)
      rescue SystemCallError
        nil
      end
    rescue StandardError, Interrupt
      File.delete(dest) if created && dest && File.exist?(dest)
      raise
    end

    def resolve_final_path(file)
      return file if @options[:in_place]

      # Default: write `<name>_clean.<ext>` next to the original. If it
      # already exists, `collision_safe` appends `_1`, `_2`, …
      collision_safe(build_clean_path(file))
    end

    def build_clean_path(file)
      ext  = File.extname(file)
      base = File.basename(file, ext)
      File.join(File.dirname(file), "#{base}#{Metaclean::CLEAN_SUFFIX}#{ext}")
    end

    # Staging path lives in the same directory as the destination so that
    # `File.rename`/`FileUtils.mv` is an atomic same-filesystem operation.
    # PID + random number prevent collisions between simultaneous runs.
    # The original extension is preserved as the LAST segment so tools like
    # mat2 — which dispatch on file extension — see the real type.
    def staging_path_for(final_path)
      dir = File.dirname(final_path)
      ext = File.extname(final_path)
      # SecureRandom (not rand) makes the staging name unpredictable, so a
      # hostile process in the same directory can't pre-create it as a symlink
      # that `FileUtils.cp` would copy the (still-sensitive) original through.
      File.join(dir, "#{Metaclean::TMP_MARKER}#{Process.pid}.#{SecureRandom.hex(8)}#{ext}")
    end

    # If `path` is taken, try `path_1`, `path_2`, … until one is free.
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

    def print_summary(summary)
      Display.header 'Summary'
      Display.success "Cleaned: #{summary[:cleaned]} file(s)"
      if summary[:unverified].positive?
        Display.warning "Unverified (clean could not be confirmed): #{summary[:unverified]} file(s)"
      end
      puts Display.error("Failed:  #{summary[:failed]}") if summary[:failed].positive?
      Display.info "Total embedded tags removed: #{summary[:removed_total]}"
      if summary[:residual_files].positive?
        Display.warning "Files with privacy residual: #{summary[:residual_files]}"
      end
      if @scan_errors.positive?
        Display.warning "Paths skipped during discovery (not found or unreadable): #{@scan_errors}"
      end
    end

    # File discovery — turning the user's paths into a flat list.

    def expand_files(paths)
      explicit   = []
      discovered = []
      paths.each do |p|
        # Symlinks are always skipped — avoids cleaning something through a link
        # that points outside the intended scope.
        if File.symlink?(p)
          Display.warning "Skipping symlink: #{p}"
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
          @scan_errors += 1
        end
      end
      discovered.reject! { |f| skip?(f) }
      dedupe_by_realpath(explicit + discovered)
    end

    # Same file via two different paths (or via symlink + direct path) should
    # be cleaned once. Comparing by realpath catches both cases. If realpath
    # raises (broken symlink, permission denied), fall back to the raw path.
    def dedupe_by_realpath(paths)
      seen = {}
      paths.each_with_object([]) do |p, acc|
        key = safe_realpath(p)
        next if seen[key]

        seen[key] = true
        acc << p
      end
    end

    # File.realpath, falling back to the raw path when it can't resolve
    # (broken symlink, permission denied) instead of raising.
    def safe_realpath(path)
      File.realpath(path)
    rescue StandardError
      path
    end

    def collect_dir(dir, out)
      if @options[:recursive]
        walk_recursive(dir, out)
      else
        # Non-recursive: just the immediate children of `dir`. Use Dir.children,
        # NOT Dir.glob("#{dir}/*") — glob interprets the WHOLE pattern, so a
        # directory name containing glob metacharacters (e.g. "Holiday [2024]")
        # matches nothing and the entire folder is silently skipped. Dir.children
        # surfaces dotfiles too; skip? filters them later, same as walk_recursive.
        Dir.children(dir).each do |entry|
          sub = File.join(dir, entry)
          next if File.symlink?(sub)

          out << sub if File.file?(sub)
        end
      end
    rescue SystemCallError => e
      # Any Errno (EACCES/ENOENT/ENOTDIR from a dir replaced mid-scan, EIO, …):
      # warn and skip this directory so one bad entry doesn't abort discovery of
      # the rest of the batch.
      Display.warning "Skipping #{dir}: #{e.message}"
      @scan_errors += 1
    end

    # Manual recursive walker. Symlinks are always skipped (never followed), so
    # the real directory tree is acyclic and no loop-guard is needed.
    def walk_recursive(dir, out)
      Dir.each_child(dir) do |entry|
        sub = File.join(dir, entry)
        next if File.symlink?(sub)

        if File.directory?(sub)
          walk_recursive(sub, out)
        elsif File.file?(sub)
          out << sub
        end
      end
    rescue SystemCallError => e
      # Any Errno (EACCES/ENOENT/ENOTDIR from a dir replaced mid-scan, EIO, …):
      # warn and skip this directory so one bad entry doesn't abort discovery of
      # the rest of the batch.
      Display.warning "Skipping #{dir}: #{e.message}"
      @scan_errors += 1
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
      return true if base =~ Metaclean::CLEAN_OUTPUT_RE
      # Matches our staging temps regardless of the pid/random suffix format.
      return true if base.include?(Metaclean::TMP_MARKER)

      false
    end
  end
end
