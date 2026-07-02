# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module Metaclean
  class Committer
    def initialize(in_place: false, dry_run: false)
      @in_place = in_place
      @dry_run = dry_run
    end

    def resolve_final_path(file)
      return file if @in_place

      collision_safe(build_clean_path(file))
    end

    def staging_path_for(final_path)
      prefix = "#{Metaclean::TMP_MARKER}runner.#{Process.pid}."
      workspace = if @dry_run
                    Dir.mktmpdir(prefix)
                  else
                    Dir.mktmpdir(prefix, File.dirname(final_path))
                  end
      FileOps.secure_workspace!(workspace)
      File.join(workspace, "staging#{File.extname(final_path)}")
    rescue StandardError, Interrupt
      FileUtils.remove_entry(workspace, true) if workspace && File.exist?(workspace)
      raise
    end

    def cleanup_staging(staging)
      return unless staging

      workspace = File.dirname(staging)
      FileUtils.remove_entry(workspace, true) if File.exist?(workspace)
    end

    def commit!(staging, final_path, source_stat:)
      backup = nil
      committed = false
      if @in_place
        FileOps.ensure_same_file!(final_path, source_stat)
        backup = backup_original(final_path, source_stat)
        File.rename(staging, final_path)
        committed = true
        return { path: final_path, backup: backup }
      end

      { path: link_with_collision_safe_name(staging, final_path), backup: nil }
    rescue SystemCallError, Interrupt
      if backup && !committed && File.exist?(staging) && FileOps.lexist?(backup)
        File.delete(backup)
      end
      raise
    end

    def backup_original(final_path, source_stat)
      backup = hardlink_with_collision_safe_name(final_path, "#{final_path}.bak")
      unless FileOps.same_identity?(File.lstat(backup), source_stat)
        File.delete(backup)
        raise Error, "#{final_path} changed during cleaning — refusing to back it up"
      end
      backup
    rescue Errno::EACCES, Errno::EPERM, Errno::ENOTSUP, Errno::EMLINK, NotImplementedError => e
      raise Error, "Cannot create a metadata-preserving hard-link backup: #{e.message}; use default copy mode"
    end

    def hardlink_with_collision_safe_name(source, preferred)
      target = preferred
      loop do
        File.link(source, target)
        return target
      rescue Errno::EEXIST
        target = collision_safe(preferred)
      end
    end

    def link_with_collision_safe_name(staging, preferred)
      target = preferred
      loop do
        File.link(staging, target)
        File.delete(staging)
        return target
      rescue Errno::EEXIST
        target = collision_safe(preferred)
      rescue Errno::EACCES, Errno::EPERM, Errno::ENOTSUP, Errno::EMLINK, NotImplementedError
        target = copy_with_collision_safe_name(staging, target)
        File.delete(staging)
        return target
      end
    end

    def copy_with_collision_safe_name(source, preferred, expected: nil)
      target = preferred
      loop do
        copy_file_exclusive(source, target, preserve: true, expected: expected)
        return target
      rescue Errno::EEXIST
        target = collision_safe(preferred)
      end
    end

    def copy_file_exclusive(source, destination, preserve: false, expected: nil)
      FileOps.copy_exclusive(source, destination, preserve: preserve, expected: expected)
    end

    def build_clean_path(file)
      extension = File.extname(file)
      base = File.basename(file, extension)
      File.join(File.dirname(file), "#{base}#{Metaclean::CLEAN_SUFFIX}#{extension}")
    end

    def collision_safe(path)
      return path unless FileOps.lexist?(path)

      extension = File.extname(path)
      base = File.basename(path, extension)
      directory = File.dirname(path)
      index = 1
      loop do
        candidate = File.join(directory, "#{base}_#{index}#{extension}")
        return candidate unless FileOps.lexist?(candidate)

        index += 1
      end
    end
  end
end
