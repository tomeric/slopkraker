module Game
  module Damage
    # What one match has done to one object, in memory. Mirrors an object_damages row
    # exactly: the bitset of what is gone, the pieces that are part way there, and how far
    # down the building has collapsed.
    #
    # The server does not simulate, so it cannot work out for itself what a car did. It
    # takes the client's word for the raw damage and applies the material's own arithmetic
    # to it -- the same absorb the client ran, from the same table -- so hardness and
    # multipliers are enforced here even though the impact was not. That is the accepted
    # price of clients reporting damage; MatchState's caps are what bound it.
    class ObjectState
      attr_reader :collapsed_from, :partial

      def initialize(surfaces:, piece_count:, rules:, destroyed: nil, partial: {}, collapsed_from: nil)
        @surfaces = surfaces
        @piece_count = piece_count.to_i
        @rules = rules
        @destroyed = PieceSet.from_blob(destroyed, @piece_count)
        # Cast on the way in: the partial column is JSON, so it comes back with string
        # keys, and looking a piece up by Integer would miss every one of them -- silently
        # restoring damaged pieces to full health on every reload.
        @partial = (partial || {}).to_h { |index, left| [ index.to_i, left.to_f ] }
        @collapsed_from = collapsed_from
        @dirty = false
      end

      # Returns the piece indices this hit broke. An index the object does not have is
      # dropped rather than raised: it arrived over a socket, and a channel is not the
      # place to crash on a malformed message.
      def apply(piece_index, raw, kind)
        return [] unless in_range?(piece_index)
        return [] unless standing?(piece_index)

        material = @surfaces.material_at(piece_index)
        # A doorway is a real index holding void. There is nothing there to break.
        return [] if material.nil? || material.name == :void

        amount = material.absorb(raw.to_f * material.multiplier_for(kind), minimum_fraction)
        return [] if amount <= 0

        left = remaining(piece_index, material) - amount
        @dirty = true

        if left > 0
          @partial[piece_index] = left
          []
        else
          destroy!(piece_index)
          [ piece_index ]
        end
      end

      # Runs the collapse rule over what is left. Returns the storey it came down from, or
      # nil if nothing changed. Everything the collapse destroyed is folded in here, so the
      # caller only has to broadcast the storey.
      def settle
        result = Collapse.evaluate(
          surfaces: @surfaces, broken: @destroyed.to_a, health: @partial,
          rules: @rules.fetch(:collapse), collapsed_from: @collapsed_from
        )
        return nil if result.collapsed_from == @collapsed_from

        result.broken.each { |index| destroy!(index) }
        @partial = result.health.except(*result.broken)
        @collapsed_from = result.collapsed_from
        @dirty = true
        @collapsed_from
      end

      def standing?(piece_index) = in_range?(piece_index) && !@destroyed.include?(piece_index)
      def broken = @destroyed.to_a
      def destroyed_blob = @destroyed.to_blob
      def destroyed_count = @destroyed.count
      def dirty? = @dirty
      def clean! = @dirty = false

      private
        def minimum_fraction = @rules.fetch(:damage).fetch(:minimum_fraction, 0.0)

        def in_range?(piece_index)
          piece_index.is_a?(Integer) && piece_index >= 0 && piece_index < @piece_count
        end

        def remaining(piece_index, material)
          @partial.fetch(piece_index) do
            surface, = @surfaces.at(piece_index)
            material.health_for(surface.cell_area, surface.thickness)
          end
        end

        def destroy!(piece_index)
          @destroyed.add(piece_index)
          @partial.delete(piece_index)
        end
    end
  end
end
