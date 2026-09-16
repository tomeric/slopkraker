module Game
  module Terrain
    # One tile of heightfield, encoded from a function of game metres.
    #
    # Walks the tile's samples rows north to south and columns west to east -- the order
    # the codec, the Tile and the sibling map app all agree on -- asking the block for the
    # height at each grid point, and packs the answers through HeightsCodec with a base
    # centred on the tile's own range. The block is the whole difference between a
    # synthetic world and an imported one: a formula here, a read from a survey raster
    # there, and everything downstream is identical.
    module TileBuilder
      Encoded = Struct.new(:tx, :tz, :base_cm, :min_cm, :max_cm, :heights, keyword_init: true)

      def self.encode(frame:, tx:, tz:)
        n = frame.height_n
        x0 = tx * frame.tile_size
        z0 = tz * frame.tile_size

        metres = Array.new(n * n) do |k|
          row, col = k.divmod(n)
          yield(x0 + col * frame.height_step, z0 + row * frame.height_step)
        end

        base_cm = HeightsCodec.base_for(metres)
        min_cm, max_cm = HeightsCodec.bounds_cm(metres)
        Encoded.new(
          tx: tx, tz: tz, base_cm: base_cm, min_cm: min_cm, max_cm: max_cm,
          heights: HeightsCodec.pack(metres, base_cm)
        )
      end
    end
  end
end
