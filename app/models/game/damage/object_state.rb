module Game
  module Damage
    # What one match has done to one object, in memory. Mirrors an object_damages row
    # exactly: the bitset of what is gone, the pieces that are part way there, and how far
    # down each of the building's bays has collapsed.
    #
    # The server does not simulate, so it cannot work out for itself what a car did. It
    # takes the client's word for the raw damage and applies the material's own arithmetic
    # to it -- the same absorb the client ran, from the same table -- so hardness and
    # multipliers are enforced here even though the impact was not. That is the accepted
    # price of clients reporting damage; MatchState's caps are what bound it.
    class ObjectState
      attr_reader :collapsed, :partial

      def initialize(surfaces:, piece_count:, rules:, destroyed: nil, partial: {}, collapsed: {})
        @surfaces = surfaces
        @piece_count = piece_count.to_i
        @rules = rules
        @destroyed = PieceSet.from_blob(destroyed, @piece_count)
        # Cast on the way in: the partial column is JSON, so it comes back with string
        # keys, and looking a piece up by Integer would miss every one of them -- silently
        # restoring damaged pieces to full health on every reload.
        @partial = (partial || {}).to_h { |index, left| [ index.to_i, left.to_f ] }
        # Bay => the storey it has come down from, and cast for the same reason: the column
        # is JSON, so the bays come back as strings, and a map keyed by strings would put
        # every collapsed dwelling back up on reload -- and with it every heap of wreckage
        # it had left, which is what gates damage to the piles. Gone through Collapse.normalise
        # rather than a bare `to_i` on the value: `nil.to_i` is 0, and 0 is the one storey that
        # means "down from the ground up", so a `{ "0" => nil }` sitting in this column would
        # read a standing building as already flat -- every heap revealed, every hit refused,
        # and no way back, since a collapsed bay may only ever move down. `settle` hands this
        # straight to `Collapse.evaluate`, so the guard has to sit here, at the column, or
        # the nil is already gone by the time evaluate's own copy of it would catch it.
        @collapsed = Collapse.normalise(collapsed || {})
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
        # Nor is there anything to break in a heap of rubble that does not exist yet. A
        # pile is DORMANT until the building falls on top of it -- reserved index space,
        # like a doorway, but reserved for something that arrives later rather than never.
        # The transition is not stored: it is implied by the collapse map, which is monotone
        # and already persisted, so this answer is the same on every client and after every
        # reload without a byte of it going on the wire.
        return [] if material.name == :rubble && !revealed?(piece_index)

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

      # Runs the collapse rule over what is left, bay by bay. Returns the bays that came
      # down (further) as [bay, storey] pairs, or [] if nothing changed. Everything the
      # collapse destroyed is folded in here, so the caller only broadcasts the pairs.
      #
      # The bays that did NOT move are left out rather than repeated: every message is
      # idempotent and every storey monotone, so a client only ever has to be told what
      # has changed, and a bay already on the ground has not.
      def settle
        result = Collapse.evaluate(
          surfaces: @surfaces, broken: @destroyed.to_a, health: @partial,
          rules: @rules.fetch(:collapse), collapsed: @collapsed
        )
        moved = result.collapsed.reject { |bay, storey| @collapsed[bay] == storey }
        return [] if moved.empty?

        result.broken.each { |index| destroy!(index) }
        @partial = result.health.except(*result.broken)
        @collapsed = result.collapsed
        # More of the house came down, so more of its wreckage is on the ground.
        @revealed_rubble = nil
        @dirty = true
        moved.to_a
      end

      def standing?(piece_index) = in_range?(piece_index) && !@destroyed.include?(piece_index)
      def broken = @destroyed.to_a
      def destroyed_blob = @destroyed.to_blob
      def destroyed_count = @destroyed.count
      def dirty? = @dirty
      def clean! = @dirty = false

      private
        def minimum_fraction = @rules.fetch(:damage).fetch(:minimum_fraction, 0.0)

        def revealed?(piece_index) = revealed_rubble.include?(piece_index)

        # Which heaps are actually on the ground. Recomputed whenever a collapse moves and
        # cached in between, because apply is on the hot path and this walks the grid.
        #
        # A bay at a time where the grid says which bay each heap belongs to, so the half
        # of a terrace that is still standing has left no wreckage to clear. A surface
        # without `bays` is one building's, and is asked for the whole of it.
        def revealed_rubble
          @revealed_rubble ||= begin
            surface = @surfaces.surfaces.find { |s| s.kind == :rubble }

            if surface.nil? || @collapsed.empty?
              []
            else
              @collapsed.flat_map do |bay, from|
                bay_key = surface.bays ? bay : nil
                Building::Rubble.pile_indices(surface, bay: bay_key).first(
                  Building::Rubble.revealed_count(
                    surface,
                    storey_count: @surfaces.storey_count,
                    collapsed_from: from,
                    bay: bay_key
                  )
                )
              end
            end
          end
        end

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
