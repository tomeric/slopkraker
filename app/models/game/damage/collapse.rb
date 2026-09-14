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

      Result = Struct.new(:collapsed_from, :broken, :health, keyword_init: true)

      # `broken` is every piece index already gone; `health` is what the pieces that have
      # been hit but not broken have left, defaulting to full. Neither is mutated.
      #
      # What comes back is `collapsed_from` -- the whole of what goes on the wire -- plus
      # the piece indices this evaluation broke, and `health` carried forward with the
      # pancake's dents applied. The caller writes those two back; the client is told only
      # the storey and works the rest out from the surfaces it already holds.
      def self.evaluate(surfaces:, broken:, rules:, health: {}, collapsed_from: nil)
        Run.new(surfaces, rules).evaluate(
          broken: broken, health: health, collapsed_from: collapsed_from
        )
      end

      class Run
        def initialize(surfaces, rules)
          @surfaces = surfaces
          @rules = rules
        end

        def evaluate(broken:, health:, collapsed_from:)
          @gone = Set.new(broken)
          @health = health.dup
          @felled = []
          @collapsed_from = collapsed_from

          cascade
          Result.new(collapsed_from: @collapsed_from, broken: @felled.sort, health: @health)
        end

        private
          attr_reader :surfaces, :rules

          # The lowest storey that fails takes the building down to there. Then the mass
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
            ceiling = @collapsed_from || surfaces.storey_count
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

          def structural_area(storey, &standing)
            surfaces.for_storey(storey).sum do |surface|
              next 0.0 unless LOAD_BEARING.include?(surface.kind)

              surface.structural_area(&standing)
            end
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

          def each_cell(from: nil, only: nil)
            surfaces.surfaces.each do |surface|
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
