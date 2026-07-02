# frozen_string_literal: true

require_relative 'test_helper'

class FfmpegTest < Minitest::Test
  def status(success)
    s = Object.new
    s.define_singleton_method(:success?) { success }
    s
  end

  def test_strip_uses_lossless_copy_and_drops_metadata
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'v.mkv')
      File.write(file, 'original')
      captured = nil
      writer = lambda do |*args|
        captured = args
        File.write(args.last.delete_prefix('file:'), 'clean')
        ['', '', status(true)]
      end
      Metaclean::Ffmpeg.stub(:available?, true) do
        Metaclean::Ffmpeg.stub(:probe_structure, { streams: [], chapters: 0 }) do
          Metaclean.stub(:capture3, writer) do
            assert_equal true, Metaclean::Ffmpeg.strip!(file)
          end
        end
      end
      assert_equal 'clean', File.read(file)
      assert_empty Dir.children(dir).grep(/#{Regexp.escape(Metaclean::TMP_MARKER)}/)
      assert_includes captured, '-map_metadata'
      assert_includes captured, '-1'
      assert_includes captured, '-c'
      assert_includes captured, 'copy'
      assert captured.first == 'ffmpeg'
      assert captured.last.start_with?('file:')
    end
  end

  def test_failure_raises
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'v.mkv')
      File.write(file, 'original')
      Metaclean::Ffmpeg.stub(:available?, true) do
        Metaclean::Ffmpeg.stub(:probe_structure, { streams: [], chapters: 0 }) do
          Metaclean.stub(:capture3, ['', 'boom', status(false)]) do
            assert_raises(Metaclean::Error) { Metaclean::Ffmpeg.strip!(file) }
          end
        end
      end
      assert_equal 'original', File.read(file)
    end
  end

  def test_success_exit_but_no_output_raises
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'v.mkv')
      File.write(file, 'original')
      Metaclean::Ffmpeg.stub(:available?, true) do
        Metaclean::Ffmpeg.stub(:probe_structure, { streams: [], chapters: 0 }) do
          Metaclean.stub(:capture3, ['', '', status(true)]) do
            assert_raises(Metaclean::Error) { Metaclean::Ffmpeg.strip!(file) }
          end
        end
      end
    end
  end

  def test_strip_rejects_attachments_that_cannot_be_verified
    structure = {
      chapters: 1,
      streams: [
        { 'index' => 0, 'codec_type' => 'audio', 'tags' => { 'language' => 'eng', 'title' => 'Private' } },
        {
          'index' => 1,
          'codec_type' => 'attachment',
          'tags' => {
            'filename' => 'Jane-private.ttf',
            'mimetype' => 'application/x-truetype-font',
            'title' => 'Private font'
          }
        }
      ]
    }
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'v.mkv')
      File.write(file, 'original')
      Metaclean::Ffmpeg.stub(:available?, true) do
        Metaclean::Ffmpeg.stub(:probe_structure, structure) do
          error = assert_raises(Metaclean::Error) { Metaclean::Ffmpeg.strip!(file) }
          assert_match(/attachments or cover art/, error.message)
        end
      end
      assert_equal 'original', File.read(file)
    end
  end

  def test_secondary_embedded_image_is_rejected_even_without_attachment_tags
    streams = [
      { 'index' => 0, 'codec_type' => 'video', 'codec_name' => 'ffv1', 'tags' => {} },
      { 'index' => 1, 'codec_type' => 'video', 'codec_name' => 'mjpeg', 'tags' => {} }
    ]
    error = assert_raises(Metaclean::Error) { Metaclean::Ffmpeg.reject_unverifiable_streams!(streams) }
    assert_match(/attachments or cover art/, error.message)
  end

  def test_strip_rejects_changed_stream_structure
    before = {
      chapters: 0,
      streams: [{ 'index' => 0, 'codec_type' => 'video', 'codec_name' => 'ffv1', 'tags' => {} }]
    }
    after = {
      chapters: 0,
      streams: [{ 'index' => 0, 'codec_type' => 'video', 'codec_name' => 'h264', 'tags' => {} }]
    }
    structures = [before, after]
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'v.mkv')
      File.write(file, 'original')
      writer = lambda do |*args|
        File.write(args.last.delete_prefix('file:'), 'changed')
        ['', '', status(true)]
      end
      Metaclean::Ffmpeg.stub(:available?, true) do
        Metaclean::Ffmpeg.stub(:probe_structure, ->(*) { structures.shift }) do
          Metaclean.stub(:capture3, writer) do
            error = assert_raises(Metaclean::Error) { Metaclean::Ffmpeg.strip!(file) }
            assert_match(/changed the stream/, error.message)
          end
        end
      end
      assert_equal 'original', File.read(file)
    end
  end
end
