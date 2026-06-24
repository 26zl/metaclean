# frozen_string_literal: true

# All terminal output lives here: ANSI colors, headers, tables, the
# before/after diff. Colors are gated on `tty?` (see color?).

module Metaclean
  module Display
    COLORS = {
      reset:   "\e[0m",
      bold:    "\e[1m",
      dim:     "\e[2m",
      red:     "\e[31m",
      green:   "\e[32m",
      yellow:  "\e[33m",
      magenta: "\e[35m",
      cyan:    "\e[36m",
      gray:    "\e[90m"
    }.freeze

    # ExifTool reports four "groups" that are descriptions of the file
    # itself, not embedded metadata: System (filesystem stat), File (header
    # info), ExifTool (its own version), Composite (computed values).
    # Excluding these makes the diff focus on what actually got stripped.
    NON_METADATA_GROUPS = %w[System File ExifTool Composite].freeze

    # ASCII wordmark shown at the top of --help / --version. Printed by `banner`
    # (see there for why it's colored line-by-line).
    LOGO = <<~ART
      ███╗   ███╗███████╗████████╗ █████╗  ██████╗██╗     ███████╗ █████╗ ███╗   ██╗
      ████╗ ████║██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║     ██╔════╝██╔══██╗████╗  ██║
      ██╔████╔██║█████╗     ██║   ███████║██║     ██║     █████╗  ███████║██╔██╗ ██║
      ██║╚██╔╝██║██╔══╝     ██║   ██╔══██║██║     ██║     ██╔══╝  ██╔══██║██║╚██╗██║
      ██║ ╚═╝ ██║███████╗   ██║   ██║  ██║╚██████╗███████╗███████╗██║  ██║██║ ╚████║
      ╚═╝     ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝
    ART

    module_function

    # Decides whether to emit ANSI color codes. Colors are wrong when:
    #   * stdout is a pipe/file (not a terminal) — `tty?` is false there
    #   * NO_COLOR env var is set (de-facto convention, see no-color.org)
    def color?
      return @color if defined?(@color)

      # Per https://no-color.org: disable only when NO_COLOR is set to a
      # non-empty value. An unset or empty NO_COLOR leaves colors on.
      no_color = ENV['NO_COLOR'].to_s
      @color = $stdout.tty? && no_color.empty?
      @color = true if ENV['FORCE_COLOR']
      @color
    end

    # Wrap text in a color, or pass it through plain when colors are off.
    def c(text, color)
      text = printable(text)
      return text unless color?

      "#{COLORS[color]}#{text}#{COLORS[:reset]}"
    end

    # Red ASCII wordmark (matches Ruby's brand color) + one-line tagline for
    # --help / --version. Colored line-by-line on purpose: `c` runs text through
    # `printable`, which turns control chars (including the heredoc's newlines)
    # into spaces — so coloring the whole block at once would collapse the logo
    # onto one line.
    def banner
      LOGO.each_line { |line| puts c(line.chomp, :red) }
      puts c('  strip EXIF · IPTC · XMP · GPS · ID3 — leave the file clean', :gray)
    end

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
      rows = rows.select { |k, _| embedded_key?(k) } if only_embedded

      if rows.empty?
        info(only_embedded ? '(no embedded metadata)' : '(no metadata)')
        return
      end

      # Group "GPS:*", "EXIF:*", … each into its own labeled sub-table.
      grouped = rows.group_by { |k, _| group_of(k) }
      grouped.sort_by { |g, _| g.to_s }.each do |group, pairs|
        puts c("  [#{group}]", :magenta)
        pairs.sort_by { |k, _| k.to_s }.each do |k, v|
          tag = k.to_s.split(':', 2).last
          line = format('    %-38s %s', truncate(tag, 38), truncate(format_value(v), 60))
          puts c(line, :dim)
        end
      end
    end

    # Compares two metadata hashes (before vs after) and prints three
    # sections: removed, changed, still-present. This is the "before/after"
    # the user asked for.
    def diff(before, after)
      keys = (before.keys + after.keys).uniq.select { |k| embedded_key?(k) }

      removed = []
      changed = []
      kept    = []

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

    # Group name out of "Group:Tag" (split caps at 2 so a ":" in the value is safe).
    def group_of(key)
      key.to_s.split(':', 2).first.to_s
    end

    # True when `key` names real embedded metadata: not the SourceFile
    # bookkeeping key, and not one of the System/File/ExifTool/Composite
    # groups that describe the file rather than its embedded tags. Single
    # source of truth for "is this a tag we actually stripped?" — shared by
    # the table, diff, count, removed-count and privacy-residual checks.
    def embedded_key?(key)
      key != 'SourceFile' && !NON_METADATA_GROUPS.include?(group_of(key))
    end

    # Make any value safe to print on a single line. Hashes/Arrays get
    # `inspect` (shows their structure); strings are collapsed to single
    # spaces so a multiline tag value doesn't wreck the table.
    def format_value(v)
      case v
      when Hash, Array then printable(v.inspect)
      else
        # Guard the regexp gsub against invalid-encoding tag values — gsub raises
        # ArgumentError on them. Exiftool.read already scrubs; this is belt-and-
        # suspenders so the display layer can never crash the run on hostile bytes.
        s = printable(v)
        s.gsub(/\s+/, ' ')
      end
    end

    # Render untrusted filenames/metadata as terminal text, not terminal control.
    # Exif/Office/PDF metadata can contain ANSI/OSC escape bytes; printing those
    # raw can recolor output, rewrite a terminal title, or worse. We keep the
    # content readable by replacing C0/DEL and C1 control chars with spaces
    # (C1, U+0080–U+009F, holds the 8-bit CSI/OSC introducers some terminals honor).
    def printable(text)
      s = text.to_s
      s = s.scrub unless s.valid_encoding?
      s.gsub(/[[:cntrl:]]/, ' ')
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
      meta.keys.count { |k| embedded_key?(k) }
    end
  end
end
