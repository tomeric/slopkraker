module Game
  module Terrain
    # What the client is told about a world's terrain before it fetches any of it: the
    # frame, and where each tile lives. Nothing here touches the database -- the World
    # builds one of these from its rows and hands it to the Scene.
    class Manifest
      attr_reader :frame, :tiles

      # `tiles` are hashes of tx, tz, base_cm, min_cm, max_cm and url. The URL is a string
      # by the time it gets here; building it is the Active Record model's business.
      def initialize(frame:, tiles:)
        @frame = frame
        @tiles = tiles
      end

      def to_spec
        frame.to_spec.merge(tiles: tiles)
      end
    end
  end
end
