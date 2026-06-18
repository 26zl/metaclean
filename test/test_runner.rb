# frozen_string_literal: true

require_relative 'test_helper'

# Runner's pure-ish logic: path/collision/skip/dedupe helpers and — most
# importantly — the clean-vs-failed status gate that defends against a
# false-clean. All testable without the external binaries.
class RunnerTest < Minitest::Test
  def setup
    @r = Metaclean::Runner.new({})
  end

  # Metaclean.safe_path (argument-injection guard)
  def test_safe_path
    assert_equal 'photo.jpg', Metaclean.safe_path('photo.jpg')
    assert_equal './-config', Metaclean.safe_path('-config')
    assert_equal '/abs/-x',   Metaclean.safe_path('/abs/-x')
    assert_equal './-x',      Metaclean.safe_path('./-x')
  end

  # ensure_tools!: all three tools are required; a partial toolchain fails fast
  # with a message naming what's missing.
  def test_ensure_tools_raises_listing_missing
    Metaclean::Exiftool.stub(:available?, true) do
      Metaclean::Mat2.stub(:available?, false) do
        Metaclean::Qpdf.stub(:available?, false) do
          err = assert_raises(Metaclean::ToolsMissing) { Metaclean.ensure_tools! }
          assert_match(/mat2/, err.message)
          assert_match(/qpdf/, err.message)
        end
      end
    end
  end

  def test_ensure_tools_passes_when_all_present
    Metaclean::Exiftool.stub(:available?, true) do
      Metaclean::Mat2.stub(:available?, true) do
        Metaclean::Qpdf.stub(:available?, true) do
          assert_nil Metaclean.ensure_tools!
        end
      end
    end
  end

  # skip? (don't re-process our own outputs)
  def test_skip_matches_own_outputs_and_hidden
    %w[photo_clean.jpg photo_clean_2.jpg a.bak .hidden.jpg
       a.metaclean.tmp.123.deadbeef.jpg].each do |name|
      assert @r.send(:skip?, name), "expected to skip #{name}"
    end
  end

  def test_skip_leaves_normal_files_including_clean_substring
    %w[photo.jpg declean.jpg vacation.png].each do |name|
      refute @r.send(:skip?, name), "expected NOT to skip #{name}"
    end
  end

  # path helpers
  def test_build_clean_path
    assert_equal 'a/b/photo_clean.jpg', @r.send(:build_clean_path, 'a/b/photo.jpg')
    assert_equal 'a/b/photo_clean',     @r.send(:build_clean_path, 'a/b/photo')
  end

  def test_staging_path_keeps_extension_last
    p = @r.send(:staging_path_for, 'a/b/photo.jpg')
    assert p.start_with?('a/b/photo.metaclean.tmp.'), p
    assert p.end_with?('.jpg'), p # mat2 dispatches on extension; must be last
  end

  def test_collision_safe_increments
    Dir.mktmpdir do |d|
      target = File.join(d, 'photo_clean.jpg')
      assert_equal target, @r.send(:collision_safe, target)
      File.write(target, 'x')
      assert_equal File.join(d, 'photo_clean_1.jpg'), @r.send(:collision_safe, target)
      File.write(File.join(d, 'photo_clean_1.jpg'), 'x')
      assert_equal File.join(d, 'photo_clean_2.jpg'), @r.send(:collision_safe, target)
    end
  end

  # dedupe_by_realpath (process each file once)
  def test_dedupe_same_file_via_two_paths
    Dir.mktmpdir do |d|
      f = File.join(d, 'a.jpg')
      File.write(f, 'x')
      out = @r.send(:dedupe_by_realpath, [f, f, File.join(d, '.', 'a.jpg')])
      assert_equal 1, out.length
    end
  end

  def test_dedupe_broken_symlink_falls_back_without_raising
    Dir.mktmpdir do |d|
      link = File.join(d, 'broken')
      File.symlink(File.join(d, 'nope'), link)
      assert_equal [link], @r.send(:dedupe_by_realpath, [link])
    end
  end

  # tools_succeeded? + finalize_result: the false-clean gate
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

  def test_finalize_failed_when_only_skipped
    res = @r.send(:finalize_result, [{ ok: false, skipped: true }], {}, {}, {})
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

  # One tool errored while another succeeded (e.g. mat2 dies, exiftool/qpdf ok):
  # the pipeline didn't fully complete, so it's :unverified, not :cleaned.
  def test_finalize_unverified_when_a_tool_errored
    results = [{ tool: :mat2, ok: false, error: 'boom' }, { tool: :exiftool, ok: true }]
    res = @r.send(:finalize_result, results, {}, {}, {})
    assert_equal :unverified, res[:status]
  end

  # A mat2 :unsupported soft-skip is NOT an error — exiftool covering the file
  # alone is still a confident clean.
  def test_finalize_cleaned_despite_soft_skip
    results = [{ tool: :mat2, ok: false, skipped: true }, { tool: :exiftool, ok: true }]
    res = @r.send(:finalize_result, results, {}, {}, {})
    assert_equal :cleaned, res[:status]
  end

  # A document format needs mat2 for coverage ExifTool can't re-read. If mat2
  # didn't actually run (absent here → exiftool-only), the empty residual can't
  # be trusted: :unverified, not a confident :cleaned.
  def test_finalize_unverified_when_mat2_essential_but_absent
    res = @r.send(:finalize_result, [{ tool: :exiftool, ok: true }], {}, {}, {}, file: 'report.docx')
    assert_equal :unverified, res[:status]
  end

  # Same document, but mat2 actually ran and stripped → confident :cleaned.
  def test_finalize_cleaned_when_mat2_ran_on_essential_format
    results = [{ tool: :mat2, ok: true }, { tool: :exiftool, ok: true }]
    res = @r.send(:finalize_result, results, {}, {}, {}, file: 'report.docx')
    assert_equal :cleaned, res[:status]
  end

  # A document ExifTool can't WRITE (docx/odt/…) soft-skips exiftool, but mat2 —
  # the authority for that format — ran and stripped, so the result is a
  # confident :cleaned, NOT :unverified. (Regression: exiftool used to hard-error
  # on these, forcing :unverified on every Office/OpenDocument file.)
  def test_finalize_cleaned_when_exiftool_soft_skips_but_mat2_ran
    results = [{ tool: :mat2, ok: true }, { tool: :exiftool, ok: false, skipped: true, note: :unsupported }]
    res = @r.send(:finalize_result, results, {}, {}, {}, file: 'report.docx')
    assert_equal :cleaned, res[:status]
  end

  # clean_one commit gate: the on-disk false-clean defense  # Drives the whole clean_one flow with the metadata/tool layer stubbed (no
  # binaries). The headline guarantee of a privacy tool: a file that is not
  # verifiably clean is NEVER written to disk, only reported :failed.

  # Tool succeeded, but a privacy tag survived the strip → must NOT write the
  # _clean output (regression test for the commit-gate-omits-residual bug).
  def test_clean_one_does_not_write_output_when_privacy_tag_survives
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original-bytes')

      out, = capture_io do
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
      assert_empty Dir.glob(File.join(d, '*.metaclean.tmp.*')), 'staging temp must be cleaned up'
      assert_match(/not writing output/, out)
    end
  end

  # No tool genuinely ran (only a soft skip) → must NOT write output even though
  # the staging file is a byte-for-byte copy of the original.
  def test_clean_one_does_not_write_output_when_no_tool_ran
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original-bytes')

      capture_io do
        @r.stub(:read_metadata, {}) do
          Metaclean::Strategy.stub(:tools_for, [:mat2]) do
            @r.stub(:run_tool, { tool: :mat2, ok: false, skipped: true }) do
              res = @r.send(:clean_one, src, index: 1, total: 1)
              assert_equal :failed, res[:status]
            end
          end
        end
      end

      refute File.exist?(File.join(d, 'photo_clean.jpg'))
      assert_empty Dir.glob(File.join(d, '*.metaclean.tmp.*'))
    end
  end

  # Genuinely clean (tool ran, no residual, ExifTool verified) → output written.
  # Proves the gate doesn't over-block.
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

  # A genuinely clean file inherits the SOURCE's permission bits, not the umask
  # default — a locked-down 0600 file must not become a world-readable 0644 copy.
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

  # A PDF pipeline where mat2 errors but exiftool/qpdf succeed: the working tools
  # cleaned what they reach, so output is written — but reported :unverified, not
  # a confident :cleaned, because the pipeline didn't fully complete.
  def test_clean_one_unverified_when_a_pipeline_tool_errors
    Dir.mktmpdir do |d|
      src = File.join(d, 'doc.pdf')
      File.write(src, 'original-bytes')
      run = ->(tool, _p) { tool == :mat2 ? { tool: :mat2, ok: false, error: 'mat2 boom' } : { tool: tool, ok: true } }
      out, = capture_io do
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
      assert File.exist?(File.join(d, 'doc_clean.pdf')), 'tools that worked cleaned it, so output is written'
      assert_match(/unverified/, out)
    end
  end

  # empty input is a non-zero exit, not silent success
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

  # expand_files: directory traversal / selection orchestration
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
      assert_equal ['a.jpg'], expand({}, [d]) # nested b.jpg not reached
    end
  end

  def test_expand_files_skips_own_outputs_and_hidden_during_discovery
    Dir.mktmpdir do |d|
      File.write(File.join(d, 'photo.jpg'), 'x')
      File.write(File.join(d, 'photo_clean.jpg'), 'x') # our own output
      File.write(File.join(d, '.secret.jpg'), 'x')     # hidden
      File.write(File.join(d, 'old.bak'), 'x')         # backup
      assert_equal ['photo.jpg'], expand({}, [d])
    end
  end

  def test_expand_files_keeps_explicit_hidden_arg
    Dir.mktmpdir do |d|
      hidden = File.join(d, '.secret.jpg')
      File.write(hidden, 'x')
      # Explicit CLI arg bypasses skip? — the user asked for this exact path.
      assert_equal ['.secret.jpg'], expand({}, [hidden])
    end
  end

  # A directory name with glob metacharacters must NOT make the non-recursive
  # scan silently match nothing (Dir.glob would); the privacy tool would
  # otherwise report "nothing to do" and leave the photos uncleaned.
  def test_expand_files_handles_glob_metacharacters_in_dirname
    Dir.mktmpdir do |d|
      sub = File.join(d, 'Holiday [2024]')
      Dir.mkdir(sub)
      File.write(File.join(sub, 'beach.jpg'), 'x')
      assert_equal ['beach.jpg'], expand({}, [sub])              # non-recursive
      assert_equal ['beach.jpg'], expand({ recursive: true }, [d]) # recursive, parent
    end
  end

  # --- in-place / backup commit path (the most data-loss-critical flow) ---
  # Drives clean_one with the binary layer stubbed and the staging file rewritten
  # to `content`, so the committed output is byte-distinguishable from any backup.
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
      assert_empty Dir.glob(File.join(d, '*.metaclean.tmp.*'))
    end
  end

  def test_clean_one_in_place_failed_rename_leaves_original_and_no_stray_bak
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'original-bytes')
      r = Metaclean::Runner.new(in_place: true)
      FileUtils.stub(:mv, ->(*) { raise Errno::EACCES }) do
        assert_raises(Errno::EACCES) { run_in_place(r, src, 'cleaned-bytes') }
      end
      assert_equal 'original-bytes', File.read(src), 'a failed commit leaves the original intact'
      refute File.exist?("#{src}.bak"), 'the now-redundant .bak is removed when the rename fails'
      assert_empty Dir.glob(File.join(d, '*.metaclean.tmp.*')), 'the staging temp is cleaned up'
    end
  end

  def test_clean_one_in_place_repeated_runs_keep_distinct_backups
    Dir.mktmpdir do |d|
      src = File.join(d, 'photo.jpg')
      File.write(src, 'v1')
      r = Metaclean::Runner.new(in_place: true)
      run_in_place(r, src, 'v2') # backs up v1 -> photo.jpg.bak
      run_in_place(r, src, 'v3') # backs up v2 -> photo.jpg_1.bak (collision_safe)
      assert_equal 'v3', File.read(src)
      assert_equal 'v1', File.read("#{src}.bak"), 'the first backup keeps the original'
      assert_equal 'v2', File.read(File.join(d, 'photo.jpg_1.bak')),
                   'a second in-place run does not clobber the first backup'
    end
  end
end
