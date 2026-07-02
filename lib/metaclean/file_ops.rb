# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module Metaclean
  module FileOps
    module_function

    def path_guard!(path)
      components = component_identities(path)
      realpath = File.realpath(path)
      raise Error, "#{path} changed while its path was being verified" unless components == component_identities(path)

      { realpath: realpath, components: components }
    rescue SystemCallError => e
      raise Error, "#{path} cannot be resolved safely: #{e.message}"
    end

    def ensure_path_guard!(path, expected)
      current = path_guard!(path)
      return if current == expected

      raise Error, "#{path} or one of its parent directories changed during cleaning"
    end

    def component_identities(path)
      components = path_components(path)
      components.map.with_index do |component, index|
        stat = File.lstat(component)
        if stat.symlink? && (index == components.length - 1 || !trusted_system_symlink?(component, stat))
          raise Error, "#{path} contains a symlink component (#{component}) — refusing to use it"
        end

        [component, stat.dev, stat.ino]
      end
    end

    def path_components(path)
      expanded = File.expand_path(path)
      current = File::SEPARATOR
      expanded.split(File::SEPARATOR).reject(&:empty?).map do |part|
        current = File.join(current, part)
      end
    end

    def trusted_system_symlink?(path, stat)
      parent = File.lstat(File.dirname(path))
      stat.uid.zero? && parent.uid.zero? && parent.mode.nobits?(0o022)
    rescue SystemCallError
      false
    end

    def regular_stat!(path)
      stat = File.lstat(path)
      raise Error, "#{path} is a symlink — refusing to use it" if stat.symlink?
      raise Error, "#{path} is not a regular file — refusing to use it" unless stat.file?

      stat
    rescue SystemCallError => e
      raise Error, "#{path} cannot be used: #{e.message}"
    end

    def ensure_same_file!(path, expected)
      current = regular_stat!(path)
      return current if same_file?(current, expected)

      raise Error, "#{path} changed during cleaning — refusing to commit"
    end

    def same_file?(left, right)
      left.dev == right.dev && left.ino == right.ino &&
        left.size == right.size && left.mtime == right.mtime && left.ctime == right.ctime
    end

    def same_identity?(left, right)
      left.dev == right.dev && left.ino == right.ino &&
        left.size == right.size && left.mtime == right.mtime
    end

    def copy_exclusive(src, dest, preserve: false, expected: nil)
      source = regular_stat!(src)
      if expected && !same_file?(source, expected)
        raise Error, "#{src} changed before it could be copied"
      end

      mode = source.mode & 0o7777
      created = false
      read_flags = File::RDONLY
      read_flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)

      File.open(dest, File::WRONLY | File::CREAT | File::EXCL, mode) do |out|
        created = true
        File.open(src, read_flags) do |input|
          opened = input.stat
          raise Error, "#{src} changed while opening — refusing to copy it" unless same_file?(opened, source)

          size = opened.size
          mtime = opened.mtime
          ctime = opened.ctime
          IO.copy_stream(input, out)
          finished = input.stat
          unless finished.size == size && finished.mtime == mtime && finished.ctime == ctime
            raise Error, "#{src} changed while it was being copied"
          end
        end
      end

      restore_metadata(dest, source) if preserve
      source
    rescue StandardError, Interrupt
      File.delete(dest) if created && dest && File.exist?(dest)
      raise
    end

    def restore_metadata(path, source_stat, strict: false)
      File.chmod(source_stat.mode & 0o7777, path)
      File.utime(source_stat.atime, source_stat.mtime, path)
    rescue SystemCallError => e
      raise Error, "Could not restore file permissions/timestamps: #{e.message}" if strict

      nil
    end

    def prepare_in_place_commit!(cleaned, source, expected)
      ensure_same_file!(source, expected)
      prepared = "#{cleaned}.metadata"
      native_metadata_copy!(source, prepared)
      copied = regular_stat!(prepared)
      unless copied.uid == expected.uid && copied.gid == expected.gid
        raise Error, 'Could not preserve source ownership for in-place output'
      end

      clean_stat = regular_stat!(cleaned)
      File.chmod((expected.mode & 0o7777) | 0o200, prepared)
      write_flags = File::WRONLY | File::TRUNC
      write_flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      File.open(prepared, write_flags) do |out|
        File.open(cleaned, File::RDONLY) { |input| IO.copy_stream(input, out) }
      end
      ensure_same_file!(cleaned, clean_stat)
      ensure_same_file!(source, expected)
      restore_metadata(prepared, expected, strict: true)
      validate_output!(prepared)
      File.rename(prepared, cleaned)
      cleaned
    rescue StandardError, Interrupt
      File.delete(prepared) if prepared && lexist?(prepared)
      raise
    end

    def native_metadata_copy!(source, destination)
      cp = find_executable('cp')
      raise Error, 'cp is required to preserve in-place filesystem metadata' unless cp

      args = if RUBY_PLATFORM.include?('darwin')
               [cp, '-p', '--', source, destination]
             elsif RUBY_PLATFORM.include?('linux')
               [cp, '--preserve=all', '--', source, destination]
             else
               raise Error, "In-place metadata preservation is unsupported on #{RUBY_PLATFORM}"
             end
      _out, err, status = Metaclean.capture3(*args)
      return if status.success?

      raise Error, "Could not preserve filesystem metadata for in-place output: #{err.strip}"
    end

    def find_executable(name)
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |directory|
        next if directory.empty?

        candidate = File.join(directory, name)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    def metadata_copy_supported?
      (RUBY_PLATFORM.include?('darwin') || RUBY_PLATFORM.include?('linux')) &&
        !find_executable('cp').nil?
    end

    def lexist?(path)
      File.symlink?(path) || File.exist?(path)
    end

    def validate_output!(path)
      stat = regular_stat!(path)
      raise Error, "#{path} is empty — refusing to use tool output" unless stat.size.positive?

      stat
    end

    def with_private_workspace(path, label)
      parent = File.dirname(File.expand_path(path))
      prefix = "#{TMP_MARKER}#{label}.#{Process.pid}."
      Dir.mktmpdir(prefix, parent) do |dir|
        secure_workspace!(dir)
        yield dir
      end
    end

    def secure_workspace!(directory)
      File.chmod(0o700, directory)
      mode = File.stat(directory).mode & 0o777
      return true if mode.nobits?(0o077)

      raise Error, "#{directory} cannot enforce a private workspace (mode #{mode.to_s(8)})"
    rescue SystemCallError => e
      raise Error, "#{directory} cannot enforce a private workspace: #{e.message}"
    end
  end
end
