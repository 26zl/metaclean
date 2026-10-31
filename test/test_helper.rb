# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'metaclean'
require 'tmpdir'
require 'zlib'
require 'digest'
require 'minitest/autorun'
require 'minitest/mock'

# Reads a PNG as [type, data] chunk pairs; shared by the integration tests and the format matrix.
module PngChunks
  SIGNATURE = "\x89PNG\r\n\x1a\n".b
  # Chunk types that only carry metadata; every other chunk must survive a clean.
  METADATA_TYPES = %w[tEXt zTXt iTXt eXIf tIME].freeze

  module_function

  def read(path)
    data = File.binread(path)
    raise ArgumentError, "#{path} is not a PNG" unless data.start_with?(SIGNATURE)

    chunks = []
    pos = SIGNATURE.bytesize
    while pos + 12 <= data.bytesize
      length = data.byteslice(pos, 4).unpack1('N')
      type = data.byteslice(pos + 4, 4)
      chunks << [type, data.byteslice(pos + 8, length)]
      pos += 12 + length
      break if type == 'IEND'
    end
    chunks
  end

  def chunk(type, data)
    [data.bytesize].pack('N') + type.b + data.b + [Zlib.crc32(type.b + data.b)].pack('N')
  end

  # Chunk types with a short digest of their bytes, readable in assertion messages.
  def fingerprint(chunks)
    chunks.map { |type, data| "#{type}:#{Digest::SHA256.hexdigest(data)[0, 10]}" }
  end

  # The ordering rules of the PNG specification for the chunks metaclean keeps.
  def ordered?(chunks)
    types = chunks.map(&:first)
    idat = types.index('IDAT')
    return false unless idat && types.first == 'IHDR' && types.last == 'IEND'

    plte = types.index('PLTE')
    colour_ok = %w[cHRM gAMA iCCP sBIT sRGB].all? { |t| !types.include?(t) || types.index(t) < (plte || idat) }
    phys_ok = %w[pHYs sPLT].all? { |t| !types.include?(t) || types.index(t) < idat }
    palette_ok = %w[bKGD hIST tRNS].all? do |t|
      i = types.index(t)
      i.nil? || (i < idat && (plte.nil? || i > plte))
    end
    colour_ok && phys_ok && palette_ok
  end
end
