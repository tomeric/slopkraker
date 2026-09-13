module Game
  module Terrain
    # Heights on the wire and in the database: signed 16-bit centimetres, little-endian,
    # offset by a per-tile base.
    #
    # Half the size of Float32, for precision five hundred times finer than the sample
    # spacing can express -- a tile samples every few metres, so resolving a centimetre is
    # already far past the point of meaning. Little-endian because the browser decodes it
    # as one Int16Array construction rather than a loop, and every machine this will ever
    # run on is little-endian anyway.
    #
    # The base is what makes the narrow type safe. Offsets are relative to the middle of
    # the tile's own range, so what has to fit in sixteen bits is the relief *within one
    # tile*, never the absolute elevation. That leaves +/-327m of range inside a 500m
    # square, which no terrain on earth comes close to needing.
    module HeightsCodec
      BYTES_PER_SAMPLE = 2
      FORMAT = "s<*" # signed 16-bit, little-endian
      MIN = -32_768
      MAX = 32_767

      class RangeError < StandardError; end

      # Centres the offsets in the available range, so the type is used symmetrically
      # rather than from one end.
      def self.base_for(metres)
        cm = metres.map { |m| (m * 100).round }
        ((cm.min + cm.max) / 2.0).round
      end

      def self.pack(metres, base_cm)
        metres.map { |m| offset(m, base_cm) }.pack(FORMAT)
      end

      def self.unpack(blob, base_cm)
        blob.unpack(FORMAT).map { |cm| (cm + base_cm) / 100.0 }
      end

      def self.bounds_cm(metres)
        cm = metres.map { |m| (m * 100).round }
        [ cm.min, cm.max ]
      end

      # Raises rather than clamping. Silently flattening a peak would produce terrain that
      # is wrong in a way nothing downstream could detect -- the physics and the render
      # mesh would agree with each other and disagree with the source.
      def self.offset(metres, base_cm)
        value = (metres * 100).round - base_cm
        return value if value.between?(MIN, MAX)

        raise RangeError,
          "#{metres}m is #{value}cm from the tile base, outside the +/-327m a tile can hold"
      end
    end
  end
end
