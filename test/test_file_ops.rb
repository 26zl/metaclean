# frozen_string_literal: true

require_relative 'test_helper'

class FileOpsTest < Minitest::Test
  F = Metaclean::FileOps

  def test_private_workspace_is_0700_and_removed_after_block
    workspace = nil
    Dir.mktmpdir do |dir|
      F.with_private_workspace(File.join(dir, 'input.bin'), 'test') do |path|
        workspace = path
        assert_equal 0o700, File.stat(path).mode & 0o777
        assert_includes File.basename(path), Metaclean::TMP_MARKER
      end
      refute File.exist?(workspace)
    end
  end

  def test_private_workspace_fails_closed_when_permissions_cannot_be_enforced
    workspace = nil
    Dir.mktmpdir do |dir|
      File.stub(:chmod, ->(*) { raise Errno::EPERM }) do
        assert_raises(Metaclean::Error) do
          F.with_private_workspace(File.join(dir, 'input.bin'), 'test') do |path|
            workspace = path
          end
        end
      end
      refute File.exist?(workspace) if workspace
      assert_empty Dir.children(dir)
    end
  end

  def test_copy_exclusive_rejects_symlink_source_and_existing_destination
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source')
      link = File.join(dir, 'link')
      destination = File.join(dir, 'destination')
      File.write(source, 'secret')
      File.symlink(source, link)
      assert_raises(Metaclean::Error) { F.copy_exclusive(link, destination) }

      File.write(destination, 'existing')
      assert_raises(Errno::EEXIST) { F.copy_exclusive(source, destination) }
      assert_equal 'existing', File.read(destination)
    end
  end

  def test_validate_output_rejects_symlinks
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'target')
      output = File.join(dir, 'output')
      File.write(target, 'data')
      File.symlink(target, output)
      assert_raises(Metaclean::Error) { F.validate_output!(output) }
    end
  end

  def test_expected_identity_detects_replacement
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source')
      replacement = File.join(dir, 'replacement')
      destination = File.join(dir, 'destination')
      File.write(source, 'first')
      expected = File.lstat(source)
      File.write(replacement, 'second')
      File.rename(replacement, source)

      assert_raises(Metaclean::Error) do
        F.copy_exclusive(source, destination, expected: expected)
      end
      refute File.exist?(destination)
    end
  end

  def test_ensure_same_file_rejects_same_inode_ctime_change
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'f')
      File.write(path, 'data')
      File.chmod(0o600, path)
      expected = File.lstat(path)
      sleep 0.01
      File.chmod(0o644, path)
      assert_raises(Metaclean::Error) { F.ensure_same_file!(path, expected) }
    end
  end

  def test_same_identity_ignores_ctime_but_not_inode
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'f')
      File.write(path, 'data')
      before = File.lstat(path)
      File.chmod(0o640, path)
      assert F.same_identity?(File.lstat(path), before), 'a mere ctime bump is still the same file'

      replacement = File.join(dir, 'r')
      File.write(replacement, 'data')
      File.rename(replacement, path)
      refute F.same_identity?(File.lstat(path), before), 'a different inode is NOT the same file'
    end
  end

  def test_copy_exclusive_keeps_file_when_metadata_restore_fails
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source')
      destination = File.join(dir, 'destination')
      File.write(source, 'payload')
      File.stub(:utime, ->(*) { raise Errno::EPERM }) do
        F.copy_exclusive(source, destination, preserve: true)
      end
      assert File.exist?(destination), 'a failed timestamp restore must not delete the complete copy'
      assert_equal 'payload', File.read(destination)
    end
  end

  def test_lexist_sees_dangling_symlink
    Dir.mktmpdir do |dir|
      link = File.join(dir, 'dangling')
      File.symlink(File.join(dir, 'nope'), link)
      refute File.exist?(link), 'precondition: exist? follows the link and sees nothing'
      assert F.lexist?(link), 'lexist? must see the dangling symlink'
    end
  end

  def test_path_guard_detects_replaced_parent_directory
    Dir.mktmpdir do |dir|
      parent = File.join(dir, 'parent')
      old_parent = File.join(dir, 'old-parent')
      FileUtils.mkdir_p(parent)
      file = File.join(parent, 'photo.jpg')
      File.write(file, 'first')
      guard = F.path_guard!(file)

      File.rename(parent, old_parent)
      FileUtils.mkdir_p(parent)
      File.write(file, 'second')
      assert_raises(Metaclean::Error) { F.ensure_path_guard!(file, guard) }
    end
  end
end
