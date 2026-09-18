module Game
  module Damage
    # Every object one match has damaged, held in memory and written down occasionally.
    #
    # Play never waits on SQLite. A batch lands in memory, the answer goes straight back
    # out over the socket, and the rows catch up about once a second -- so the worst a
    # process restart costs is a second of wreckage, and the client's monotone state makes
    # even that invisible.
    #
    # The one class under game/ that touches the database, and only because it is handed a
    # Match rather than going looking for one. It reads through that record's associations
    # and never queries by key or slug.
    class MatchState
      # Bounds on what one batch can reach. Be honest about what these are: they are not
      # security. The server cannot recompute damage without simulating, which is the
      # accepted price of clients reporting it. They bound the blast radius of a bad
      # client, nothing more, and there is no ranked play.
      MAX_HITS_PER_BATCH = 512
      MAX_AMOUNT_PER_HIT = 5_000.0

      def initialize(match, rules:)
        @match = match
        @rules = rules
        @objects = {}
      end

      def apply_batch(hits)
        broken = []
        touched = {}
        all = Array(hits)
        # The cap bounds a bad client; it must never be silent. What is dropped is reported
        # back so the sender knows its view and the server's have parted.
        truncated = all.length > MAX_HITS_PER_BATCH

        all.first(MAX_HITS_PER_BATCH).each do |hit|
          next unless hit.is_a?(Array) && hit.length >= 3

          object_id, piece_index, amount, kind = hit
          state = state_of(object_id)
          next unless state

          capped = [ amount.to_f, MAX_AMOUNT_PER_HIT ].min
          state.apply(piece_index, capped, (kind || "impact").to_s).each do |index|
            broken << [ object_id.to_i, index ]
            touched[object_id.to_i] = state
          end
        end

        # Once per object rather than once per hit: a collapse is a property of the
        # building after the whole batch has landed, not of any one panel in it.
        collapses = touched.filter_map do |object_id, state|
          storey = state.settle
          storey && [ object_id, storey ]
        end

        { "broken" => broken, "collapses" => collapses, "truncated" => truncated }
      end

      # What a joining client needs to catch up. Deliberately only what is GONE: partial
      # health is cosmetic and local, so darkening a chipped wall is the client's business
      # and has no business on the wire.
      def state_for(object_ids)
        Array(object_ids).filter_map do |object_id|
          state = state_of(object_id)
          next unless state

          {
            "id" => object_id.to_i,
            "broken" => Base64.strict_encode64(state.destroyed_blob),
            "broken_count" => state.destroyed_count,
            "collapsed_from" => state.collapsed_from
          }
        end
      end

      def rehydrate!
        ObjectDamage.where(match: @match).find_each do |row|
          object = objects_by_id[row.world_object_id]
          next unless object&.building?

          @objects[row.world_object_id] = build_state(object, row)
        end
      end

      # One statement, inside a transaction that takes SQLite's write lock at BEGIN.
      #
      # That matters more than it looks. SQLite's classic deadlock is two DEFERRED
      # transactions each taking a read lock and then both trying to upgrade to a write;
      # neither can, and one dies on a busy timeout. Taking the write lock up front removes
      # the upgrade and therefore the deadlock.
      #
      # Rails 8.1's SQLite3 adapter already does this -- `default_transaction_mode:
      # :immediate` is its default and this app does not override it in database.yml -- so
      # a plain `transaction` is already an IMMEDIATE one. Passing `isolation: :immediate`
      # here raises, because it is a transaction mode rather than an isolation level. If
      # that default is ever changed in database.yml, this flush is what breaks first.
      def flush!
        dirty = @objects.select { |_, state| state.dirty? }
        return 0 if dirty.empty?

        now = Time.current
        rows = dirty.map do |object_id, state|
          {
            match_id: @match.id, world_object_id: object_id,
            broken_pieces: state.destroyed_blob, partial: state.partial,
            collapsed_from: state.collapsed_from, broken_count: state.destroyed_count,
            updated_at: now
          }
        end

        ApplicationRecord.transaction do
          ObjectDamage.upsert_all(rows, unique_by: %i[match_id world_object_id])
        end

        dirty.each_value(&:clean!)
        rows.length
      end

      private
        def state_of(object_id)
          id = object_id.to_i
          return @objects[id] if @objects.key?(id)

          object = objects_by_id[id]
          # A crate is one dynamic body that tumbles, not a grid of pieces. Only a building
          # has piece indices to report damage against.
          return nil unless object&.building?

          @objects[id] = build_state(object, nil)
        end

        def build_state(object, row)
          ObjectState.new(
            surfaces: object.surface_set, piece_count: object.piece_count, rules: @rules,
            destroyed: row&.broken_pieces, partial: row&.partial || {},
            collapsed_from: row&.collapsed_from
          )
        end

        def objects_by_id
          @objects_by_id ||= @match.world.world_objects.index_by(&:id)
        end
    end
  end
end
