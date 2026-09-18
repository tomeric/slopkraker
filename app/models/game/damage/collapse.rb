module Game
  module Damage
    # A storey that can no longer hold itself up takes everything above it with it.
    #
    # DELIBERATELY NOT PORTED TO JAVASCRIPT, unlike every other per-frame behaviour in
    # this codebase. The temptation will recur, so here is why it must not be:
    #
    # Individual breaks are safe to predict on the client because they are monotone and
    # self-caused -- you hit a panel, the panel goes, and the server can only ever agree
    # sooner. A collapse is neither. It is caused by the sum of what every player has
    # done to a building, so a client holding only its own view of the damage would fire
    # it at the wrong moment; and it is the one event that cannot be walked back, because
    # it destroys a hundred pieces and spawns a debris field. A mispredicted break is a
    # panel flickering back. A mispredicted collapse is a house that was never there.
    #
    # So the server decides, and says so in twenty bytes: [object_id, from_storey]. The
    # client already holds the surfaces, so expanding that back into pieces is a filter.
    module Collapse
      # Walls and partitions hold a storey up. A floor deck is carried by them rather than
      # carrying them, and a roof is a hat.
      LOAD_BEARING = %i[wall partition].freeze

      # What a shared wall is worth to each of the bays leaning on it. Counted in full a
      # mid-terrace dwelling keeps 70% of its support with its front and back gone and never
      # falls; at half it comes down, an end dwelling needs its partition as well, and a
      # party wall taken out condemns both neighbours.
      SHARED_WEIGHT = 0.5

      Result = Struct.new(:collapsed, :broken, :health, keyword_init: true)

      # Casts a collapse map's keys and values to Integer, the way it has to be read
      # wherever it comes off JSON -- a wire message here, an `object_damages` row a frame
      # earlier in ObjectState. A bay with no storey is a bay that has not come down, and it
      # is dropped rather than coerced. `nil.to_i` is 0, and 0 is the one value that means
      # "down from the ground up": a `{ "0" => nil }` surviving this cast would read as a
      # building already flat, which reveals all of its wreckage, refuses every hit on it
      # and can never be raised back -- the one direction this map may not move. Both
      # readers call this rather than casting on their own, because they have to agree.
      def self.normalise(collapsed)
        collapsed.filter_map { |bay, storey| [ bay.to_i, storey.to_i ] unless storey.nil? }.to_h
      end

      # `broken` is every piece index already gone; `health` is what the pieces that have
      # been hit but not broken have left, defaulting to full. Neither is mutated.
      #
      # `collapsed` is the map of bay => storey it has already come down from. Every bay is
      # weighed; the bays that fail fell their own surfaces, never a shared one, so no bay's
      # fall changes a neighbour's support and a row does not domino.
      #
      # What comes back is that map with every bay that failed added or lowered -- the whole
      # of what goes on the wire -- plus the piece indices this evaluation broke, and
      # `health` carried forward with the pancake's dents applied. The caller writes those
      # two back; the client is told only the storey and works the rest out from the
      # surfaces it already holds.
      def self.evaluate(surfaces:, broken:, rules:, health: {}, collapsed: {})
        gone = Set.new(broken)
        left = health.dup
        felled = []
        result = normalise(collapsed)

        surfaces.bays.each do |bay|
          run = Run.new(surfaces, rules, bay: bay, gone: gone, health: left, felled: felled)
          storey = run.evaluate(collapsed_from: result[bay])
          result[bay] = storey unless storey.nil?
        end

        Result.new(collapsed: result, broken: felled.sort, health: left)
      end

      class Run
        def initialize(surfaces, rules, bay:, gone:, health:, felled:)
          @rules = rules
          @bay = bay
          parts = surfaces.for_bay(bay)
          @own = parts[:own]
          @shared = parts[:shared]
          @storey_count = surfaces.storey_count
          @gone = gone
          @health = health
          @felled = felled
        end

        # The storey this bay has come down to after this evaluation, or nil if it moved
        # nowhere. Shares `gone`, `health` and `felled` with every other bay's run, because
        # a shared wall broken by a hit is gone for both of its neighbours.
        def evaluate(collapsed_from:)
          @collapsed_from = collapsed_from
          before = collapsed_from

          cascade
          @collapsed_from == before ? nil : @collapsed_from
        end

        private
          attr_reader :rules

          # The lowest storey that fails takes the bay down to there. Then the mass
          # that just fell lands on the storey below, which may or may not take it --
          # which is what makes a top-floor failure sometimes reach the ground and usually
          # stop one floor down. Bounded by storey_count because each pass moves strictly
          # downward.
          #
          # Note what the load clause does here: once a storey has come down there is
          # nothing left standing above the one below it, so its load drops to nothing and
          # only the integrity clause can still condemn it. A cascade therefore has to be
          # earned by the pancake actually breaking things, rather than following
          # automatically from the collapse above.
          def cascade
            storey = lowest_failing
            return unless storey

            loop do
              falling = fell_from(storey)
              @collapsed_from = storey
              return if storey.zero?

              storey -= 1
              pancake(falling, onto: storey)
              return unless fails?(storey)
            end
          end

          # Never above a collapse that has already happened: there is nothing standing up
          # there to fail, and reporting it would raise `collapsed_from`, which is the one
          # direction it may not move.
          #
          # Every storey below that is weighed rather than only the ones just hit. A hit
          # anywhere changes the load on every storey under it, so "touched" is not a
          # smaller set than "all" by much, and a building this only runs for when
          # something has actually hit it.
          def lowest_failing
            ceiling = @collapsed_from || @storey_count
            (0...ceiling).find { |storey| fails?(storey) }
          end

          # Two ways for a storey to give.
          #
          # The first is integrity: a storey with almost nothing left of it fails whatever
          # is above, which is what stops a roof hanging in the air over a top floor that
          # has been shot out. Nothing is above it to weigh, so only this clause can catch
          # it.
          #
          # The second is the one that carries the feel. What matters is not how many
          # walls are gone but how much support went with them, measured against how much
          # weight is still up there needing carrying:
          #
          #   support = the storey's load-bearing area still standing, over what it had
          #   load    = the mass still standing above it, over what was there
          #
          # A storey fails when load outruns support by more than the safety factor. Both
          # halves are fractions of the building's own intact state, so the rule is free
          # of any absolute area or tonnage and reads the same on a bungalow and a tower.
          #
          # It is also what makes the building answer back. Take a long wall out of the
          # ground floor of a three-storey house and you have removed a quarter of what
          # holds two storeys up -- do it twice and it comes down on you. Knock the roof
          # and the top floor off first and the same two walls hold, because there is
          # nothing left for them to carry. Demolition has an order to it.
          def fails?(storey)
            capacity = capacity_fraction(storey)
            return true if capacity < rules.fetch(:threshold)

            load_fraction(storey) / capacity > rules.fetch(:safety_factor)
          end

          def capacity_fraction(storey)
            intact = intact_capacity(storey)
            return 1.0 if intact.zero?

            structural_area(storey) { |index| standing?(index) } / intact
          end

          def load_fraction(storey)
            intact = intact_load(storey)
            return 0.0 if intact.zero?

            mass_above(storey) { |index| standing?(index) } / intact
          end

          def intact_capacity(storey)
            @intact_capacity ||= {}
            @intact_capacity[storey] ||= structural_area(storey)
          end

          def intact_load(storey)
            @intact_load ||= {}
            @intact_load[storey] ||= mass_above(storey)
          end

          # The bay's own load-bearing area in full, plus half of every wall it shares.
          def structural_area(storey, &standing)
            own = @own.select { |s| s.storey == storey && LOAD_BEARING.include?(s.kind) }.sum { |s| s.structural_area(&standing) }
            shared = @shared.select { |s| s.storey == storey }.sum { |s| s.structural_area(&standing) }
            own + shared * SHARED_WEIGHT
          end

          # Everything a storey is holding up: every piece of every storey above it, not
          # only the load-bearing ones, because a floor deck and a roof press down just as
          # honestly as a wall does.
          def mass_above(storey, &standing)
            total = 0.0

            each_cell(from: storey + 1) do |surface, row, col, index|
              next if standing && !standing.call(index)

              total += surface.material_at(row, col).mass_for(surface.cell_area, surface.thickness)
            end

            total
          end

          # Everything at or above the failed storey goes at once, and the mass of what
          # was still standing is what comes down on the floor below. Weighed before it is
          # destroyed, for the obvious reason.
          def fell_from(storey)
            mass = 0.0

            each_cell(from: storey) do |surface, row, col, index|
              next unless standing?(index)

              material = surface.material_at(row, col)
              mass += material.mass_for(surface.cell_area, surface.thickness)
              break!(index)
            end

            mass
          end

          # Spread evenly over what holds the storey below up. Only load-bearing cells
          # take it: they are what the next evaluation weighs, so damaging anything else
          # would be damage with no consequence. An intact storey shrugs a pancake off; a
          # storey already chewed up by the fight that brought the one above down is
          # finished by it.
          def pancake(mass, onto:)
            targets = load_bearing_cells(onto)
            return if targets.empty?

            each = mass * rules.fetch(:pancake_damage_fraction) / targets.length

            targets.each do |surface, row, col, index|
              left = remaining(surface, row, col, index) - each

              if left <= 0
                break!(index)
              else
                @health[index] = left
              end
            end
          end

          def load_bearing_cells(storey)
            [].tap do |cells|
              each_cell(only: storey) do |surface, row, col, index|
                next unless LOAD_BEARING.include?(surface.kind)
                next unless standing?(index)
                next unless surface.material_at(row, col).structural?

                cells << [ surface, row, col, index ]
              end
            end
          end

          # Own surfaces only. A shared wall carries itself, and is never felled from here:
          # a bay bringing a party wall down would take its neighbour's support with it, and
          # a terrace would domino from one end to the other on a single hit.
          def each_cell(from: nil, only: nil)
            @own.each do |surface|
              # Rubble is the wreckage a collapse LEAVES, so no collapse may sweep it: not
              # to destroy it, not to weigh it as load, not to count it as support. Its
              # storey of -1 already puts it outside every bound here, and this says so out
              # loud, because the failure would be silent and permanent -- a house that
              # quietly never leaves any wreckage, with nothing downstream looking wrong.
              # A hedge is the garden a house stands behind, at the same storey of -1 for
              # the same reason: nothing a collapse does reaches it.
              next if %i[rubble hedge].include?(surface.kind)
              next if from && surface.storey < from
              next if only && surface.storey != only

              surface.rows.times do |row|
                surface.cols.times do |col|
                  yield surface, row, col, surface.piece_index(row, col)
                end
              end
            end
          end

          def remaining(surface, row, col, index)
            @health.fetch(index) do
              surface.material_at(row, col).health_for(surface.cell_area, surface.thickness)
            end
          end

          def standing?(index) = !@gone.include?(index)

          def break!(index)
            @gone << index
            @health.delete(index)
            @felled << index
          end
      end
    end
  end
end
