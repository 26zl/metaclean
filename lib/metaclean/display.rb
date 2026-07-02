# frozen_string_literal: true

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

    NON_METADATA_GROUPS = %w[System File ExifTool Composite].freeze

    LOGO = <<~ART
      ███╗   ███╗███████╗████████╗ █████╗  ██████╗██╗     ███████╗ █████╗ ███╗   ██╗
      ████╗ ████║██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║     ██╔════╝██╔══██╗████╗  ██║
      ██╔████╔██║█████╗     ██║   ███████║██║     ██║     █████╗  ███████║██╔██╗ ██║
      ██║╚██╔╝██║██╔══╝     ██║   ██╔══██║██║     ██║     ██╔══╝  ██╔══██║██║╚██╗██║
      ██║ ╚═╝ ██║███████╗   ██║   ██║  ██║╚██████╗███████╗███████╗██║  ██║██║ ╚████║
      ╚═╝     ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝
    ART

    module_function

    def configure(quiet: false, redact_values: false)
      @quiet = quiet
      @redact_values = redact_values
    end

    def quiet?
      @quiet == true
    end

    def redact_values?
      @redact_values == true
    end

    def color?
      return @color if defined?(@color)

      @color = if !ENV['NO_COLOR'].to_s.empty?
                 false
               elsif !ENV['FORCE_COLOR'].to_s.empty?
                 true
               else
                 $stdout.tty?
               end
    end

    def c(text, color)
      text = printable(text)
      return text unless color?

      "#{COLORS[color]}#{text}#{COLORS[:reset]}"
    end

    def banner
      LOGO.each_line { |line| puts c(line.chomp, :red) }
      puts c('  strip EXIF · IPTC · XMP · GPS · ID3 — leave the file clean', :gray)
    end

    def header(text)
      return if quiet?

      puts
      puts c('━' * 64, :gray)
      puts c(text, :bold)
      puts c('━' * 64, :gray)
    end

    def section(text); puts c("▸ #{text}",  :cyan) unless quiet?;  end
    def info(text);    puts c("  #{text}",  :gray) unless quiet?;  end
    def success(text); puts c("✓ #{text}",  :green) unless quiet?; end
    def warning(text); warn c("⚠ #{text}",  :yellow);end

    def error(text); c("✗ #{text}", :red); end

    def metadata_table(meta, only_embedded: false)
      return if quiet?

      rows = meta.reject { |k, _| k == 'SourceFile' }
      rows = rows.select { |k, _| embedded_key?(k) } if only_embedded

      if rows.empty?
        info(only_embedded ? '(no embedded metadata)' : '(no metadata)')
        return
      end

      grouped = rows.group_by { |k, _| group_of(k) }
      grouped.sort_by { |g, _| g.to_s }.each do |group, pairs|
        puts c("  [#{group}]", :magenta)
        pairs.sort_by { |k, _| k.to_s }.each do |k, v|
          tag = k.to_s.split(':', 2).last
          line = format('    %-38s %s', truncate(tag, 38), truncate(visible_value(v), 60))
          puts c(line, :dim)
        end
      end
    end

    def diff(before, after)
      return if quiet?

      removed, changed, kept = classify_diff(before, after)
      render_removed(removed)
      render_changed(changed)
      render_kept(kept)

      if [removed, changed, kept].all?(&:empty?)
        info 'Nothing to strip — file already clean.'
      elsif removed.empty? && changed.empty?
        info 'No tags were removed — see "Still present" above.'
      end
    end

    def classify_diff(before, after)
      rows = [[], [], []]
      keys = (before.keys + after.keys).uniq.select { |key| embedded_key?(key) }
      keys.sort.each do |key|
        old_value = before[key]
        new_value = after[key]
        if new_value.nil? && !old_value.nil?
          rows[0] << [key, old_value]
        elsif !old_value.nil? && new_value != old_value
          rows[1] << [key, old_value, new_value]
        elsif !old_value.nil?
          rows[2] << [key, old_value]
        end
      end
      rows
    end

    def render_removed(rows)
      return if rows.empty?

      section "Removed (#{rows.size})"
      rows.each do |key, value|
        puts "  #{c('-', :red)} #{c(key, :red)}  #{c(truncate(visible_value(value), 60), :gray)}"
      end
    end

    def render_changed(rows)
      return if rows.empty?

      section "Changed (#{rows.size})"
      rows.each do |key, old_value, new_value|
        puts "  #{c('~', :yellow)} #{c(key, :yellow)}"
        puts "      #{c('-', :red)}   #{truncate(visible_value(old_value), 60)}"
        puts "      #{c('+', :green)} #{truncate(visible_value(new_value), 60)}"
      end
    end

    def render_kept(rows)
      return if rows.empty?

      section "Still present (#{rows.size})"
      rows.each do |key, value|
        puts "  #{c('=', :gray)} #{c(key, :gray)}  #{c(truncate(visible_value(value), 60), :gray)}"
      end
    end

    def group_of(key)
      key.to_s.split(':', 2).first.to_s
    end

    def embedded_key?(key)
      key != 'SourceFile' && !NON_METADATA_GROUPS.include?(group_of(key))
    end

    def format_value(v)
      case v
      when Hash, Array then printable(v.inspect)
      else
        s = printable(v)
        s.gsub(/\s+/, ' ')
      end
    end

    def visible_value(value)
      redact_values? ? '[redacted]' : format_value(value)
    end

    def printable(text)
      s = text.to_s
      s = s.scrub unless s.valid_encoding?
      s.gsub(/[[:cntrl:]]/, ' ')
    end

    def truncate(s, n)
      s = s.to_s
      s.length > n ? "#{s[0, n - 1]}…" : s
    end

    def count_embedded(meta)
      meta.keys.count { |k| embedded_key?(k) }
    end
  end
end
