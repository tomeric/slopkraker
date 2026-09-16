module Game
  module Terrain
    # The ground under the `hills` world, as a function of game metres.
    #
    # Three cosines. Every term is a cosine rather than a sine so that every gradient is
    # zero at the origin: the spawn stands on a level hilltop and rolls nowhere until the
    # player drives. The relief is about +/-7.7m over the 400m world. The smallest term has
    # a 13m by 17m wavelength, which twists each 5m cell by up to twelve centimetres --
    # that twist is what makes the two possible diagonals of a cell disagree by several
    # centimetres at its centre, and so what gives the terrain probe test something to
    # catch. A smoother function would pass that test whatever Rapier did.
    #
    # Ruby only. The client never evaluates this; it receives the encoded bytes over the
    # tile endpoint, which is what makes comparing its sampler against ours a real test
    # rather than two copies of one formula.
    module Hills
      # Two hundred metre tiles rather than the five hundred metre default: four of them
      # cover the 400m world exactly and put both seams through the middle, where the
      # tests drive. Chunks are 100 because 125 does not divide 200 and World insists.
      FRAME = Frame.new(tile_size: 200, height_step: 5, chunk_size: 100)
      TILES = [ -1, 0 ].product([ -1, 0 ]).freeze

      def self.height_at(x, z)
        4.0 * Math.cos(x / 37.0) * Math.cos(z / 29.0) +
          2.5 * Math.cos((x + z) / 53.0) +
          1.2 * Math.cos(x / 13.0 - z / 17.0)
      end

      def self.tile(tx, tz)
        TileBuilder.encode(frame: FRAME, tx: tx, tz: tz) { |x, z| height_at(x, z) }
      end

      # Where something with a level base stands on a slope: the mean of the ground under
      # its four corners, so it is buried as far uphill as it is clear downhill. This is
      # the seeder's concern that the persistent-world design assigns to `world_objects.y`,
      # and it stays out of the recipe.
      def self.base_height(x, z, width, depth)
        corners = [ [ x, z ], [ x + width, z ], [ x + width, z + depth ], [ x, z + depth ] ]
        corners.sum { |cx, cz| height_at(cx, cz) } / corners.length
      end
    end
  end
end
