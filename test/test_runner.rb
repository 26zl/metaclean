# frozen_string_literal: true

require_relative 'test_helper'
require 'timeout'

class RunnerTest < Minitest::Test
  def setup
    @r = Metaclean::Runner.new({})
    @discovery = Metaclean::Discovery.new
  end

  def metaclean_temps(dir)
    Dir.children(dir).grep(/\.metaclean\.tmp\./)
  end

  def test_safe_path
    assert_equal 'photo.jpg', Metaclean.safe_path('photo.jpg')
    assert_equal './-config', Metaclean.safe_path('-config')
    assert_equal '/abs/-x',   Metaclean.safe_path('/abs/-x')
    assert_equal './-x',      Metaclean.safe_path('./-x')
  end

  def test_ensure_tools_raises_listing_missing
    Metaclean::Exiftool.stub(:available?, true) do
      Metaclean::Mat2.stub(:available?, false) do
        Metaclean::Qpdf.stub(:available?, false) do
          Metaclean::Ffmpeg.stub(:available?, false) do
            err = assert_raises(Metaclean::ToolsMissing) { Metaclean.ensure_tools! }
            assert_match(/mat2/, err.message)
            assert_match(/qpdf/, err.message)
            assert_match(/ffmpeg/, err.message)
          end
        end
      end
    end
  end

  def test_ensure_tools_passes_when_all_present
    Metaclean::Exiftool.stub(:available?, true) do
      Metaclean::Mat2.stub(:available?, true) do
        Metaclean::Qpdf.stub(:available?, true) do
          Metaclean::Ffmpeg.stub(:available?, true) do
            assert_nil Metaclean.ensure_tools!
          end
        end
      end
    end
  end

  def test_ensure_tools_requires_metadata_preserving_cp_for_in_place
    Metaclean::Exiftool.stub(:available?, true) do
      Metaclean::Mat2.stub(:available?, true) do
        Metaclean::Qpdf.stub(:available?, true) do
          Metaclean::Ffmpeg.stub(:available?, true) do
            Metaclean::FileOps.stub(:metadata_copy_supported?, false) do
              error = assert_raises(Metaclean::ToolsMissing) { Metaclean.ensure_tools!(in_place: true) }
              assert_match(/cp with metadata preservation/, error.message)
            end
          end
        end
      end
    end
  end

  def test_skip_matches_own_outputs_and_hidden
    %w[photo_clean.jpg photo_clean_2.jpg photo_clean photo_clean_2 a.bak .hidden.jpg
       a.metaclean.tmp.123.deadbeef.jpg].each do |name|
      assert @discovery.skip?(name), "expected to skip #{name}"
    end
  end

  def test_skip_leaves_normal_files_including_clean_substring
    %w[photo.jpg declean.jpg vacation.png].each do |name|
      refute @discovery.skip?(name), "expected NOT to skip #{name}"
    end
  end

  def test_private_workspaces_use_shared_marker_and_mode_0700
    Dir.mktmpdir do |dir|
      Metaclean::FileOps.with_private_workspace(File.join(dir, 'x.mkv'), 'test') do |workspace|
        assert_includes File.basename(workspace), Metaclean::TMP_MARKER
        assert_equal 0o700, File.stat(workspace).mode & 0o777
      end
    end
  end

  def test_build_clean_path
    assert_equal 'a/b/photo_clean.jpg', @r.send(:build_clean_path, 'a/b/photo.jpg')
    assert_equal 'a/b/photo_clean',     @r.send(:build_clean_path, 'a/b/photo')
  end

  def test_staging_path_keeps_extension_last
    Dir.mktmpdir do |dir|
      path = @r.send(:staging_path_for, File.join(dir, 'photo.jpg'))
      assert_includes File.basename(File.dirname(path)), Metaclean::TMP_MARKER
      assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
      assert path.end_with?('.jpg'), path
      @r.send(:cleanup_staging, path)
    end
  end

  def test_dry_run_stages_outside_read_only_source_directory
    Dir.mktmpdir do |dir|
      source_dir = File.join(dir, 'readonly')
      Dir.mkdir(source_dir)
      runner = Metaclean::Runner.new(dry_run: true)
      staging = runner.send(:staging_path_for, File.join(source_dir, 'photo.jpg'))
      refute File.expand_path(staging).start_with?("#{File.expand_path(source_dir)}#{File::SEPARATOR}")
      runner.send(:cleanup_staging, staging)
    end
  end

  def test_collision_safe_increments
    Dir.mktmpdir do |d|
      target = File.join(d, 'photo_clean.jpg')
      assert_equal target, @r.send(:collision_safe, target)
      File.write(target, 'x')
      assert_equal File.join(d, 'photo_clean_1.jpg'), @r.send(:collision_safe, target)
      File.write(File.join(d, 'photo_clean_1.jpg'), 'x')
      assert_equal File.join(d, 'photo_clean_2.jpg'), @r.send(:collision_safe, target)

      numeric = File.join(d, 'photo_2024.jpg')
      File.write(numeric, 'x')
      assert_equal File.join(d, 'photo_2024_1.jpg'), @r.send(:collision_safe, numeric)
    end
  end

  def test_copy_file_exclusive_refuses_symlink_source
    Dir.mktmpdir do |d|
      real = File.join(d, 'real.jpg')
      link = File.join(d, 'link.jpg')
      dest = File.join(d, 'out.jpg')
      File.write(real, 'x')
      File.symlink(real, link)

      assert_raises(Metaclean::Error) { @r.send(:copy_file_exclusive, link, dest) }
      refute File.exist?(dest), 'failed exclusive copy must not leave an output file'
    end
  end

  def test_dedupe_same_file_via_two_paths
    Dir.mktmpdir do |d|
      f = File.join(d, 'a.jpg')
      File.write(f, 'x')
      out = @discovery.dedupe_by_realpath([f, f, File.join(d, '.', 'a.jpg')])
      assert_equal 1, out.length
    end
  end

  def test_dedupe_broken_symlink_falls_back_without_raising
    Dir.mktmpdir do |d|
      link = File.join(d, 'broken')
      File.symlink(File.join(d, 'nope'), link)
      assert_equal [link], @discovery.dedupe_by_realpath([link])
    end
  end

  def test_tools_succeeded
    assert @r.send(:tools_succeeded?, [{ ok: true }])
    assert @r.send(:tools_succeeded?, [{ ok: false }, { ok: true }])
    refute @r.send(:tools_succeeded?, [{ ok: true, skipped: true }])
    refute @r.send(:tools_succeeded?, [{ ok: false }])
    refute @r.send(:tools_succeeded?, [])
  end

  def test_finalize_cleaned_only_when_tool_ran_and_no_residual
    res = @r.send(:finalize_result, [{ ok: true }], {}, {}, {})
    assert_equal :cleaned, res[:status]
  end

  def test_finalize_failed_when_residual_present
    res = @r.send(:finalize_result, [{ ok: true }], {}, {}, { 'GPS:GPSLatitude' => 1 })
    assert_equal :failed, res[:status]
  end

  def test_finalize_unsupported_when_no_tool_runs
    res = @r.send(:finalize_result, [{ ok: false, skipped: true }], {}, {}, {})
    assert_equal :unsupported, res[:status]
  end

  def test_finalize_failed_when_no_tool_runs_but_privacy_tag_survives
    res = @r.send(:finalize_result, [{ ok: false, skipped: true }], {}, {}, { 'GPS:GPSLatitude' => 59.9 })
    assert_equal :failed, res[:status]
  end

  def test_finalize_failed_when_only_errored
    res = @r.send(:finalize_result, [{ ok: false, error: 'boom' }], {}, {}, {})
    assert_equal :failed, res[:status]
  end

  def test_finalize_counts_removed_embedded_tags
    res = @r.send(:finalize_result, [{ ok: true }], { 'IFD0:Artist' => 'J' }, {}, {})
    assert_equal 1, res[:removed]
  end

  def test_finalize_unverified_when_a_tool_errored
    results = [{ tool: :mat2, ok: false, error: 'boom' }, { tool: :exiftool, ok: true }]
    res = @r.send(:finalize_result, results, {}, {}, {})
    assert_equal :unverified, res[:status]
  end

  def test_finalize_cleaned_despite_soft_skip
    results = [{ tool: :mat2, ok: false, skipped: true }, { tool: :exiftool, ok: true }]
    res = @r.send(:finalize_result, results, {}, {}, {})
    assert_equal :cleaned, res[:status]
  end

  def test_finalize_unverified_when_mat2_essential_but_absent
    res = @r.send(:finalize_result, [{ tool: :exiftool, ok: true }], {}, {}, {}, file: 'report.docx')
    assert_equal :unverified, res[:status]
  end

  def test_finalize_cleaned_when_mat2_ran_on_essential_format
    results = [{ tool: :mat2, ok: true }, { tool: :exiftool, ok: true }]
    res = @r.send(:finalize_result, results, {}, {}, {}, file: 'report.docx')
    assert_equal :cleaned, res[:status]
  end

  def test_finalize_cleaned_when_exiftool_soft_skips_but_mat2_ran
    results = [{ tool: :mat2, ok: true }, { tool: :exiftool, ok: false, skipped: true, note: :unsupported }]
    res = @r.send(:finalize_result, results, {}, {}, {}, file: 'report.docx')
    assert_equal :cleaned, res[:status]
  end

  def test_clean_one_does_not_write_output_when_privacy_tag_survives
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original-bytes')

      _out, err = capture_io do
        @r.stub(:read_metadata, { 'GPS:GPSLatitude' => 59.9 }) do
          Metaclean::Strategy.stub(:tools_for, [:exiftool]) do
            @r.stub(:run_tool, { tool: :exiftool, ok: true }) do
              res = @r.send(:clean_one, src, index: 1, total: 1)
              assert_equal :failed, res[:status]
            end
          end
        end
      end

      refute File.exist?(File.join(d, 'photo_clean.jpg')),
             'a file with a surviving privacy tag must not be written'
      assert_equal 'original-bytes', File.read(src), 'original must be left untouched'
      assert_empty metaclean_temps(d), 'staging temp must be cleaned up'
      assert_match(/not writing output/, err)
    end
  end

  def test_clean_one_does_not_write_output_when_file_comment_survives
    Dir.mktmpdir do |d|
      src = File.join(d, 'archive.zip')
      File.write(src, 'original-bytes')

      _out, err = capture_io do
        @r.stub(:read_metadata, { 'File:Comment' => 'secret archive comment' }) do
          Metaclean::Strategy.stub(:tools_for, [:mat2]) do
            @r.stub(:run_tool, { tool: :mat2, ok: true }) do
              res = @r.send(:clean_one, src, index: 1, total: 1)
              assert_equal :failed, res[:status]
            end
          end
        end
      end

      refute File.exist?(File.join(d, 'archive_clean.zip')),
             'a surviving File:Comment must not be written as clean'
      assert_match(/not writing output/, err)
    end
  end

  def test_clean_one_skips_dangling_symlink_target_without_looping
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original')
      File.symlink(File.join(d, 'nonexistent'), File.join(d, 'photo_clean.jpg'))

      Timeout.timeout(15) do
        capture_io do
          Metaclean::Exiftool.stub(:available?, true) do
            @r.stub(:read_metadata, {}) do
              Metaclean::Strategy.stub(:tools_for, [:exiftool]) do
                @r.stub(:run_tool, ->(t, p) { File.write(p, 'clean'); { tool: t, ok: true } }) do
                  assert_equal :cleaned, @r.send(:clean_one, src, index: 1, total: 1)[:status]
                end
              end
            end
          end
        end
      end

      assert_equal 'clean', File.read(File.join(d, 'photo_clean_1.jpg'))
    end
  end

  def test_clean_one_aborts_if_source_changes_in_place_during_cleaning
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original')
      File.chmod(0o600, src)
      run = lambda do |tool, path|
        File.chmod(0o644, src)
        File.write(path, 'cleaned')
        { tool: tool, ok: true }
      end

      assert_raises(Metaclean::Error) do
        capture_io do
          @r.stub(:read_metadata, {}) do
            Metaclean::Strategy.stub(:tools_for, [:exiftool]) do
              @r.stub(:run_tool, run) { @r.send(:clean_one, src, index: 1, total: 1) }
            end
          end
        end
      end
      refute File.exist?(File.join(d, 'photo_clean.jpg')), 'a source changed mid-clean is not committed'
    end
  end

  def test_clean_one_in_place_backup_is_a_hardlink_to_the_original_inode
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original-bytes')
      original_ino = File.stat(src).ino
      run_in_place(Metaclean::Runner.new(in_place: true), src, 'cleaned-bytes')

      backup = "#{src}.bak"
      assert_equal 'original-bytes', File.read(backup)
      assert_equal original_ino, File.stat(backup).ino, 'the .bak shares the original inode'
      refute_equal original_ino, File.stat(src).ino, 'the cleaned file is a different inode'
    end
  end

  def test_clean_one_reports_unsupported_and_writes_nothing_when_no_tool_ran
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original-bytes')

      _out, err = capture_io do
        @r.stub(:read_metadata, {}) do
          Metaclean::Strategy.stub(:tools_for, [:mat2]) do
            @r.stub(:run_tool, { tool: :mat2, ok: false, skipped: true }) do
              res = @r.send(:clean_one, src, index: 1, total: 1)
              assert_equal :unsupported, res[:status]
            end
          end
        end
      end

      refute File.exist?(File.join(d, 'photo_clean.jpg'))
      assert_equal 'original-bytes', File.read(src), 'original must be left untouched'
      assert_empty metaclean_temps(d)
      assert_match(/supports this format/i, err)
    end
  end

  def test_clean_one_writes_output_when_genuinely_clean
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original-bytes')

      capture_io do
        Metaclean::Exiftool.stub(:available?, true) do
          @r.stub(:read_metadata, {}) do
            Metaclean::Strategy.stub(:tools_for, [:exiftool]) do
              @r.stub(:run_tool, { tool: :exiftool, ok: true }) do
                res = @r.send(:clean_one, src, index: 1, total: 1)
                assert_equal :cleaned, res[:status]
              end
            end
          end
        end
      end

      assert File.exist?(File.join(d, 'photo_clean.jpg')), 'a genuinely clean file should be written'
    end
  end

  def test_clean_one_default_output_does_not_clobber_late_collision
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      preferred = File.join(d, 'photo_clean.jpg')
      File.write(src, 'original-bytes')

      capture_io do
        @r.stub(:read_metadata, {}) do
          Metaclean::Strategy.stub(:tools_for, [:exiftool]) do
            @r.stub(:run_tool, ->(t, p) { File.write(preferred, 'user-file'); File.write(p, 'clean'); { tool: t, ok: true } }) do
              assert_equal :cleaned, @r.send(:clean_one, src, index: 1, total: 1)[:status]
            end
          end
        end
      end

      assert_equal 'user-file', File.read(preferred), 'late-created _clean file must not be overwritten'
      assert_equal 'clean', File.read(File.join(d, 'photo_clean_1.jpg'))
    end
  end

  def test_default_commit_falls_back_when_hardlinks_are_unavailable
    Dir.mktmpdir do |d|
      staging = File.join(d, '.metaclean.tmp.test.jpg')
      final = File.join(d, 'photo_clean.jpg')
      File.write(staging, 'clean')

      File.stub(:link, ->(*) { raise Errno::EPERM }) do
        assert_equal final, @r.send(:link_with_collision_safe_name, staging, final)
      end

      assert_equal 'clean', File.read(final)
      refute File.exist?(staging)
    end
  end

  def test_clean_one_preserves_source_permissions
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'x')
      File.chmod(0o600, src)
      capture_io do
        Metaclean::Exiftool.stub(:available?, true) do
          @r.stub(:read_metadata, {}) do
            Metaclean::Strategy.stub(:tools_for, [:exiftool]) do
              @r.stub(:run_tool, ->(t, p) { File.write(p, 'c'); { tool: t, ok: true } }) do
                @r.send(:clean_one, src, index: 1, total: 1)
              end
            end
          end
        end
      end
      assert_equal 0o600, File.stat(File.join(d, 'photo_clean.jpg')).mode & 0o777,
                   'the cleaned copy must keep the original 0600 permissions'
    end
  end

  def test_clean_one_aborts_if_source_is_replaced_during_cleaning
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      replacement = File.join(d, 'replacement.jpg')
      File.write(src, 'original')
      File.write(replacement, 'new-data')
      run = lambda do |tool, path|
        File.rename(replacement, src)
        File.write(path, 'cleaned-original')
        { tool: tool, ok: true }
      end

      assert_raises(Metaclean::Error) do
        capture_io do
          @r.stub(:read_metadata, {}) do
            Metaclean::Strategy.stub(:tools_for, [:exiftool]) do
              @r.stub(:run_tool, run) { @r.send(:clean_one, src, index: 1, total: 1) }
            end
          end
        end
      end
      assert_equal 'new-data', File.read(src)
      refute File.exist?(File.join(d, 'photo_clean.jpg'))
      assert_empty metaclean_temps(d)
    end
  end

  def test_clean_one_does_not_write_unverified_pipeline_output
    Dir.mktmpdir do |d|
      src = File.join(d, 'doc.pdf')
      File.write(src, 'original-bytes')
      run = ->(tool, _p) { tool == :mat2 ? { tool: :mat2, ok: false, error: 'mat2 boom' } : { tool: tool, ok: true } }
      _out, err = capture_io do
        Metaclean::Exiftool.stub(:available?, true) do
          @r.stub(:read_metadata, {}) do
            Metaclean::Strategy.stub(:tools_for, %i[mat2 exiftool qpdf]) do
              @r.stub(:run_tool, run) do
                assert_equal :unverified, @r.send(:clean_one, src, index: 1, total: 1)[:status]
              end
            end
          end
        end
      end
      refute File.exist?(File.join(d, 'doc_clean.pdf'))
      assert_match(/could not be verified/, err)
    end
  end

  def test_inspect_paths_exits_nonzero_when_no_files
    err = assert_raises(SystemExit) { capture_io { @r.inspect_paths(['/no/such/path']) } }
    assert_equal 1, err.status
  end

  def test_clean_paths_exits_nonzero_when_no_files
    err = assert_raises(SystemExit) { capture_io { @r.clean_paths(['/no/such/path']) } }
    assert_equal 1, err.status
  end

  def test_clean_paths_exits_nonzero_when_any_file_unverified
    r = Metaclean::Runner.new(force: true)
    result = { status: :unverified, removed: 0, residual: 0 }
    r.stub(:expand_files, ['doc.pdf']) do
      r.stub(:announce_tools, nil) do
        r.stub(:clean_one, result) do
          err = assert_raises(SystemExit) { capture_io { r.clean_paths(['doc.pdf']) } }
          assert_equal 1, err.status
        end
      end
    end
  end

  def test_clean_paths_exits_nonzero_when_all_files_unsupported
    r = Metaclean::Runner.new(force: true)
    result = { status: :unsupported, removed: 0, residual: 0 }
    r.stub(:expand_files, ['notes.txt']) do
      r.stub(:announce_tools, nil) do
        r.stub(:clean_one, result) do
          err = assert_raises(SystemExit) { capture_io { r.clean_paths(['notes.txt']) } }
          assert_equal 1, err.status
        end
      end
    end
  end

  def expand(options, paths)
    files = nil
    capture_io { files = Metaclean::Runner.new(options).send(:expand_files, paths) }
    files.map { |f| File.basename(f) }.sort
  end

  def test_expand_files_non_recursive_is_immediate_children_only
    Dir.mktmpdir do |d|
      File.write(File.join(d, 'a.jpg'), 'x')
      Dir.mkdir(File.join(d, 'sub'))
      File.write(File.join(d, 'sub', 'b.jpg'), 'x')
      assert_equal ['a.jpg'], expand({}, [d])
    end
  end

  def test_expand_files_skips_own_outputs_and_hidden_during_discovery
    Dir.mktmpdir do |d|
      File.write(File.join(d, 'photo.jpg'), 'x')
      File.write(File.join(d, 'photo_clean.jpg'), 'x')
      File.write(File.join(d, '.secret.jpg'), 'x')
      File.write(File.join(d, 'old.bak'), 'x')
      assert_equal ['photo.jpg'], expand({}, [d])
    end
  end

  def test_expand_files_does_not_descend_into_hidden_directories
    Dir.mktmpdir do |d|
      hidden = File.join(d, '.private')
      Dir.mkdir(hidden)
      File.write(File.join(hidden, 'secret.jpg'), 'x')
      File.write(File.join(d, 'public.jpg'), 'x')
      assert_equal ['public.jpg'], expand({ recursive: true }, [d])
    end
  end

  def test_expand_files_keeps_explicit_hidden_arg
    Dir.mktmpdir do |d|
      hidden = File.join(d, '.secret.jpg')
      File.write(hidden, 'x')
      assert_equal ['.secret.jpg'], expand({}, [hidden])
    end
  end

  def test_expand_files_handles_glob_metacharacters_in_dirname
    Dir.mktmpdir do |d|
      sub = File.join(d, 'Holiday [2024]')
      Dir.mkdir(sub)
      File.write(File.join(sub, 'beach.jpg'), 'x')
      assert_equal ['beach.jpg'], expand({}, [sub])
      assert_equal ['beach.jpg'], expand({ recursive: true }, [d])
    end
  end

  def run_in_place(runner, src, content)
    out = nil
    capture_io do
      Metaclean::Exiftool.stub(:available?, true) do
        runner.stub(:read_metadata, {}) do
          Metaclean::Strategy.stub(:tools_for, [:exiftool]) do
            runner.stub(:run_tool, ->(t, p) { File.write(p, content); { tool: t, ok: true } }) do
              out = runner.send(:clean_one, src, index: 1, total: 1)
            end
          end
        end
      end
    end
    out
  end

  def test_clean_one_in_place_overwrites_and_backs_up_original
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original-bytes')
      res = run_in_place(Metaclean::Runner.new(in_place: true), src, 'cleaned-bytes')
      assert_equal :cleaned, res[:status]
      assert_equal 'cleaned-bytes', File.read(src), 'the original is overwritten in place'
      assert_equal 'original-bytes', File.read("#{src}.bak"), 'a .bak preserves the original bytes'
      assert_empty metaclean_temps(d)
    end
  end

  def test_clean_one_in_place_failed_rename_leaves_original_and_no_stray_bak
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original-bytes')
      r = Metaclean::Runner.new(in_place: true)
      File.stub(:rename, lambda { |from, to|
        raise Errno::EPERM if to == src

        File.unlink(to) if File.exist?(to)
        File.link(from, to)
        File.unlink(from)
      }) do
        assert_raises(Errno::EPERM) { run_in_place(r, src, 'cleaned-bytes') }
      end
      assert_equal 'original-bytes', File.read(src), 'a failed rename leaves the original intact'
      refute File.exist?("#{src}.bak"), 'the now-redundant .bak is removed when the rename fails'
      assert_empty metaclean_temps(d), 'the staging temp is cleaned up'
    end
  end

  def test_clean_one_in_place_interrupt_after_rename_keeps_backup
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original-bytes')
      r = Metaclean::Runner.new(in_place: true)

      File.stub(:rename, lambda { |from, to|
        unless to == src
          File.unlink(to) if File.exist?(to)
          File.link(from, to)
          File.unlink(from)
          next
        end
        File.unlink(to)
        File.link(from, to)
        File.unlink(from)
        raise Interrupt
      }) do
        assert_raises(Interrupt) { run_in_place(r, src, 'cleaned-bytes') }
      end

      assert_equal 'cleaned-bytes', File.read(src), 'rename already completed'
      assert_equal 'original-bytes', File.read("#{src}.bak"), 'backup must survive a post-rename interrupt'
      assert_empty metaclean_temps(d), 'the staging temp is gone after the completed rename'
    end
  end

  def test_clean_one_in_place_repeated_runs_keep_distinct_backups
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'v1')
      r = Metaclean::Runner.new(in_place: true)
      run_in_place(r, src, 'v2')
      run_in_place(r, src, 'v3')
      assert_equal 'v3', File.read(src)
      assert_equal 'v1', File.read("#{src}.bak"), 'the first backup keeps the original'
      assert_equal 'v2', File.read(File.join(d, 'photo.jpg_1.bak')),
                   'a second in-place run does not clobber the first backup'
    end
  end

  def test_clean_one_in_place_does_not_clobber_existing_backup_collision
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      backup = "#{src}.bak"
      File.write(src, 'original-bytes')
      File.write(backup, 'user-backup')
      r = Metaclean::Runner.new(in_place: true)

      run_in_place(r, src, 'cleaned-bytes')

      assert_equal 'user-backup', File.read(backup), 'existing .bak must not be overwritten'
      assert_equal 'original-bytes', File.read(File.join(d, 'photo.jpg_1.bak'))
      assert_equal 'cleaned-bytes', File.read(src)
    end
  end

  def test_in_place_fails_closed_when_hard_link_backup_is_unavailable
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'photo.jpg')
      File.write(source, 'original-bytes')
      runner = Metaclean::Runner.new(in_place: true)

      File.stub(:link, ->(*) { raise Errno::EPERM }) do
        error = assert_raises(Metaclean::Error) { run_in_place(runner, source, 'cleaned-bytes') }
        assert_match(/hard-link backup/, error.message)
      end
      assert_equal 'original-bytes', File.read(source)
      refute File.exist?("#{source}.bak")
    end
  end

  def test_run_tool_ffmpeg_success
    capture_io do
      Metaclean::Ffmpeg.stub(:strip!, true) do
        assert_equal({ tool: :ffmpeg, ok: true }, @r.send(:run_tool, :ffmpeg, 'v.mkv'))
      end
    end
  end

  def test_run_tool_ffmpeg_error_is_caught_not_raised
    res = nil
    capture_io do
      Metaclean::Ffmpeg.stub(:strip!, ->(_p) { raise Metaclean::Error, "boom\nstack\ntrace" }) do
        res = @r.send(:run_tool, :ffmpeg, 'v.mkv')
      end
    end
    assert_equal :ffmpeg, res[:tool]
    refute res[:ok]
  end

  def test_run_tool_exiftool_forwards_also_delete
    seen = :unset
    capture_io do
      Metaclean::Exiftool.stub(:strip!, ->(_p, also_delete:) { seen = also_delete; true }) do
        @r.send(:run_tool, :exiftool, 'a.tiff')
      end
    end
    assert_equal Metaclean::Strategy::PRIVACY_TAGS, seen
  end

  def test_finalize_cleaned_for_ffmpeg_only_mkv
    res = @r.send(:finalize_result, [{ tool: :ffmpeg, ok: true }], {}, {}, {}, file: 'clip.mkv')
    assert_equal :cleaned, res[:status]
  end

  def test_finalize_cleaned_when_exiftool_soft_skips_riff_or_svg
    %w[clip.avi clip.wav pic.svg].each do |f|
      results = [{ tool: :mat2, ok: true }, { tool: :exiftool, ok: false, skipped: true, note: :unsupported }]
      assert_equal :cleaned, @r.send(:finalize_result, results, {}, {}, {}, file: f)[:status], f
    end
  end

  def test_clean_one_mkv_via_ffmpeg_writes_cleaned
    Dir.mktmpdir do |d|
      src = File.join(d, 'video.mkv')
      File.write(src, 'original')
      capture_io do
        Metaclean::Exiftool.stub(:available?, true) do
          @r.stub(:read_metadata, {}) do
            Metaclean::Strategy.stub(:tools_for, [:ffmpeg]) do
              @r.stub(:run_tool, { tool: :ffmpeg, ok: true }) do
                assert_equal :cleaned, @r.send(:clean_one, src, index: 1, total: 1)[:status]
              end
            end
          end
        end
      end
      assert File.exist?(File.join(d, 'video_clean.mkv'))
    end
  end

  def test_clean_one_dry_run_writes_nothing
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original')
      r = Metaclean::Runner.new(dry_run: true)
      workspace_mode = nil
      capture_io do
        Metaclean::Exiftool.stub(:available?, true) do
          r.stub(:read_metadata, {}) do
            Metaclean::Strategy.stub(:tools_for, [:exiftool]) do
              run = lambda do |tool, path|
                workspace_mode = File.stat(File.dirname(path)).mode & 0o777
                { tool: tool, ok: true }
              end
              r.stub(:run_tool, run) do
                r.send(:clean_one, src, index: 1, total: 1)
              end
            end
          end
        end
      end
      refute File.exist?(File.join(d, 'photo_clean.jpg')), 'dry-run writes no output'
      assert_equal 'original', File.read(src), 'dry-run leaves the original untouched'
      assert_empty metaclean_temps(d), 'dry-run leaves no staging temp'
      assert_equal 0o700, workspace_mode
    end
  end

  def test_expand_files_skips_symlink_argument
    Dir.mktmpdir do |d|
      real = File.join(d, 'real.jpg')
      File.write(real, 'x')
      link = File.join(d, 'link.jpg')
      File.symlink(real, link)
      assert_equal ['real.jpg'], expand({}, [link, real])
    end
  end

  def test_expand_files_skips_symlinked_file_in_directory
    Dir.mktmpdir do |d|
      File.write(File.join(d, 'a.jpg'), 'x')
      File.symlink(File.join(d, 'a.jpg'), File.join(d, 'b.jpg'))
      assert_equal ['a.jpg'], expand({}, [d])
    end
  end

  def test_expand_files_rejects_symlink_in_parent_component
    Dir.mktmpdir do |dir|
      outside = File.join(dir, 'outside')
      Dir.mkdir(outside)
      file = File.join(outside, 'secret.jpg')
      File.write(file, 'x')
      link = File.join(dir, 'linked-dir')
      File.symlink(outside, link)

      runner = Metaclean::Runner.new({})
      _out, err = capture_io do
        assert_empty runner.send(:expand_files, [File.join(link, 'secret.jpg')])
      end
      assert_match(/symlink component/, err)
    end
  end

  def test_force_in_place_still_warns_about_metadata_backup
    runner = Metaclean::Runner.new(force: true, in_place: true)
    _out, err = capture_io do
      runner.stub(:expand_files, ['photo.jpg']) do
        runner.stub(:announce_tools, nil) do
          runner.stub(:clean_one, { status: :cleaned, removed: 0, residual: 0 }) do
            runner.clean_paths(['photo.jpg'])
          end
        end
      end
    end
    assert_match(/backup is the ORIGINAL/i, err)
  end

  def test_warnings_are_written_to_stderr_not_stdout
    out, err = capture_io { Metaclean::Display.warning('privacy note') }
    assert_empty out, 'warnings must not pollute stdout'
    assert_match(/privacy note/, err)
  end

  def test_report_residual_hints_at_allow_icc_metadata_only_for_icc_only_residual
    _out, err = capture_io do
      @r.send(:report_residual, { 'ICC-header:ProfileDescription' => 'ACME Corp Custom' })
    end
    assert_match(/--allow-icc-metadata/, err)

    _out, err = capture_io do
      @r.send(:report_residual, { 'GPS:GPSLatitude' => 59.9 })
    end
    refute_match(/--allow-icc-metadata/, err)
  end

  def run_with_stdin(input)
    r = Metaclean::Runner.new({})
    ran = []
    status = 0
    orig = $stdin
    $stdin = StringIO.new(input)
    begin
      capture_io do
        r.stub(:expand_files, ['photo.jpg']) do
          r.stub(:announce_tools, nil) do
            r.stub(:clean_one, ->(*) { ran << :ran; { status: :cleaned, removed: 0, residual: 0 } }) do
              r.clean_paths(['photo.jpg'])
            end
          end
        end
      end
    rescue SystemExit => e
      status = e.status
    end
    [ran, status]
  ensure
    $stdin = orig
  end

  def test_confirmation_prompt_proceeds_on_yes
    ran, status = run_with_stdin("y\n")
    assert_equal [:ran], ran
    assert_equal 0, status
  end

  def test_confirmation_prompt_aborts_on_blank_enter
    ran, status = run_with_stdin("\n")
    assert_empty ran
    assert_equal 1, status, 'a blank-Enter abort must exit non-zero'
  end

  def test_confirmation_prompt_aborts_on_eof
    ran, status = run_with_stdin('')
    assert_empty ran
    assert_equal 1, status, 'an EOF abort must exit non-zero'
  end

  def test_clean_paths_exits_nonzero_when_a_path_could_not_be_scanned
    Dir.mktmpdir do |d|
      good = File.join(d, 'a.jpg')
      File.write(good, 'x')
      r = Metaclean::Runner.new(force: true)
      r.stub(:announce_tools, nil) do
        r.stub(:clean_one, { status: :cleaned, removed: 0, residual: 0 }) do
          err = assert_raises(SystemExit) do
            capture_io { r.clean_paths([good, File.join(d, 'does-not-exist')]) }
          end
          assert_equal 1, err.status
        end
      end
    end
  end

  def test_inspect_paths_exits_nonzero_when_a_file_cannot_be_read
    Dir.mktmpdir do |d|
      f = File.join(d, 'a.jpg')
      File.write(f, 'x')
      Metaclean::Exiftool.stub(:read, ->(_p) { raise Metaclean::Error, 'unreadable' }) do
        err = assert_raises(SystemExit) { capture_io { @r.inspect_paths([f]) } }
        assert_equal 1, err.status
      end
    end
  end
end
