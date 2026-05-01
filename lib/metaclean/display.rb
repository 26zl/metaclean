# frozen_string_literal: true

# ───────────────────────────────────────────────────────────────────────────
# Anything that prints to the terminal lives here: ANSI colors, headers,
# tables, the before/after diff. Keeping presentation in one module means
# the rest of the codebase stays focused on logic.
#
# ANSI escape sequences:
#   "\e[31m" turns the terminal text red.
#   "\e[0m"  resets all styling.
# A modern terminal interprets these; if you redirect to a file, they show
# up as garbage — that's why we check `tty?` before emitting them.
# ───────────────────────────────────────────────────────────────────────────

module Metaclean
  module Display
    COLORS = {
      reset:   "\e[0m",
      bold:    "\e[1m",
      dim:     "\e[2m",
      red:     "\e[31m",
      green:   "\e[32m",
      yellow:  "\e[33m",
      blue:    "\e[34m",
      magenta: "\e[35m",
      cyan:    "\e[36m",
      gray:    "\e[90m"
    }.freeze

    # ExifTool reports four "groups" that are descriptions of the file
    # itself, not embedded metadata: System (filesystem stat), File (header
    # info), ExifTool (its own version), Composite (computed values).
    # Excluding these makes the diff focus on what actually got stripped.
    NON_METADATA_GROUPS = %w[System File ExifTool Composite].freeze

    module_function

    # Decides whether to emit ANSI color codes. Colors are wrong when:
    #   * stdout is a pipe/file (not a terminal) — `tty?` is false there
    #   * NO_COLOR env var is set (de-facto convention, see no-color.org)
    #   * we're on classic Windows cmd.exe (modern Windows Terminal is fine,
    #     but to be safe we require an explicit FORCE_COLOR opt-in there)
    def color?
      return @color if defined?(@color)

      # Per https://no-color.org: disable only when NO_COLOR is set to a
      # non-empty value. An unset or empty NO_COLOR leaves colors on.
      no_color = ENV['NO_COLOR'].to_s
      @color = $stdout.tty? && no_color.empty? && !Gem.win_platform?
      @color = true if ENV['FORCE_COLOR']
      @color
    end

    # `c` for "color". Wraps text in the requested color, or returns it
    # plain if colors are disabled. The reset code at the end stops the
    # color from bleeding into following output.
    def c(text, color)
      return text.to_s unless color?

      "#{COLORS[color]}#{text}#{COLORS[:reset]}"
    end

    # Visual section markers used throughout the runner's output. Keeping
    # them here means a single change updates the look everywhere.
    def header(text)
      puts
      puts c('━' * 64, :gray)
      puts c(text, :bold)
      puts c('━' * 64, :gray)
    end

    def section(text); puts c("▸ #{text}",  :cyan);  end
    def info(text);    puts c("  #{text}",  :gray);  end
    def success(text); puts c("✓ #{text}",  :green); end
    def warning(text); puts c("⚠ #{text}",  :yellow);end

    # `error` returns a string instead of printing it — callers usually want
    # to send it to STDERR via `warn`, not stdout via `puts`.
    def error(text); c("✗ #{text}", :red); end

    # Prints a metadata Hash as a grouped, indented table.
    # `only_embedded:` filters out the System/File/etc. noise.
    def metadata_table(meta, only_embedded: false)
      rows = meta.reject { |k, _| k == 'SourceFile' }
      rows = rows.reject { |k, _| NON_METADATA_GROUPS.include?(group_of(k)) } if only_embedded

      if rows.empty?
        info(only_embedded ? '(no embedded metadata)' : '(no metadata)')
        return
      end

      # `group_by` partitions an Enumerable into a Hash keyed by the block's
      # result. Here we group all "GPS:*" tags together, all "EXIF:*" together,
      # etc., then print each group as a labeled sub-table.
      grouped = rows.group_by { |k, _| group_of(k) }
      grouped.sort_by { |g, _| g.to_s }.each do |group, pairs|
        puts c("  [#{group}]", :magenta)
        pairs.sort_by { |k, _| k.to_s }.each do |k, v|
          tag = k.to_s.split(':', 2).last
          # `format` (alias of sprintf) does column alignment: %-38s = left-
          # aligned, padded to 38 chars.
          line = format('    %-38s %s', truncate(tag, 38), truncate(format_value(v), 60))
          puts c(line, :dim)
        end
      end
    end

    # Compares two metadata hashes (before vs after) and prints three
    # sections: removed, changed, still-present. This is the "before/after"
    # the user asked for.
    def diff(before, after)
      keys = (before.keys + after.keys).uniq
                                       .reject { |k| k == 'SourceFile' }
                                       .reject { |k| NON_METADATA_GROUPS.include?(group_of(k)) }

      removed = []
      changed = []
      kept    = []

      # Classifying each key into one of three buckets keeps the rest of
      # the method simple and testable.
      keys.sort.each do |k|
        b = before[k]
        a = after[k]
        if a.nil? && !b.nil?
          removed << [k, b]
        elsif !b.nil? && a != b
          changed << [k, b, a]
        elsif !b.nil?
          kept << [k, b]
        end
      end

      if removed.any?
        section "Removed (#{removed.size})"
        removed.each do |k, b|
          puts "  #{c('-', :red)} #{c(k, :red)}  #{c(truncate(format_value(b), 60), :gray)}"
        end
      end

      if changed.any?
        section "Changed (#{changed.size})"
        changed.each do |k, b, a|
          puts "  #{c('~', :yellow)} #{c(k, :yellow)}"
          puts "      #{c('-', :red)}   #{truncate(format_value(b), 60)}"
          puts "      #{c('+', :green)} #{truncate(format_value(a), 60)}"
        end
      end

      if kept.any?
        section "Still present (#{kept.size})"
        kept.each do |k, b|
          puts "  #{c('=', :gray)} #{c(k, :gray)}  #{c(truncate(format_value(b), 60), :gray)}"
        end
      end

      if removed.empty? && changed.empty? && kept.empty?
        info 'Nothing to strip — file already clean.'
      elsif removed.empty? && changed.empty?
        info 'No tags were removed — see "Still present" above.'
      end
    end

    # Pull the group name out of "Group:Tag". The `2` argument to split caps
    # the result at 2 elements, so a value containing ":" doesn't break it.
    def group_of(key)
      key.to_s.split(':', 2).first.to_s
    end

    # Make any value safe to print on a single line. Hashes/Arrays get
    # `inspect` (shows their structure); strings are collapsed to single
    # spaces so a multiline tag value doesn't wreck the table.
    def format_value(v)
      case v
      when Hash, Array then v.inspect
      else v.to_s.gsub(/\s+/, ' ')
      end
    end

    # Truncate to N chars with a single-character ellipsis. We use "…"
    # (one Unicode char) instead of "..." so the truncation doesn't itself
    # spill over the budget.
    def truncate(s, n)
      s = s.to_s
      s.length > n ? "#{s[0, n - 1]}…" : s
    end

    # How many "real" embedded tags are there? Used for the
    # "Before (24 embedded tags) → After (0)" summary line.
    def count_embedded(meta)
      meta.keys
          .reject { |k| k == 'SourceFile' }
          .reject { |k| NON_METADATA_GROUPS.include?(group_of(k)) }
          .size
    end
  end
end
