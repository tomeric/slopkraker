module Game
  module Damage
    # The live wreckage of every match this process is running, one MatchState each behind
    # its own lock.
    #
    # Process-global on purpose. Destruction is authoritative in exactly one process:
    # config/puma.rb has no `workers` line, so that is true by construction today, and
    # ArenaChannel's authority claim is what makes it enforced rather than merely true.
    # Two processes each holding their own copy of this would diverge silently, which is
    # the failure this design refuses to allow.
    module Registry
      FLUSH_EVERY = 1.0

      @monitor = Monitor.new
      @states = {}
      @locks = {}
      @sweeper = nil

      class << self
        # Yields the match's state with nobody else inside it. A batch has to land whole:
        # two threads interleaving inside one would each read the health of a piece the
        # other was about to break.
        def checkout(match)
          sweeping!
          lock_for(match.id).synchronize do
            state = state_for(match)
            yield state
          end
        end

        # Every live match, written down. One pass, each match under its own lock, and
        # only the objects that actually changed.
        def flush_all!
          ids = @monitor.synchronize { @states.keys }

          ids.sum do |match_id|
            lock_for(match_id).synchronize do
              @monitor.synchronize { @states[match_id] }&.flush! || 0
            end
          end
        end

        # Last one out writes the wreckage down. Everything after this point comes back
        # from the rows rather than from memory.
        def release(match)
          lock_for(match.id).synchronize do
            @monitor.synchronize { @states.delete(match.id) }&.flush!
          end
          @monitor.synchronize { @locks.delete(match.id) }
        end

        # Drops everything without writing it down. A test hook, and only that -- a real
        # release always flushes first.
        def reset!
          @monitor.synchronize do
            @sweeper&.shutdown
            @sweeper = nil
            @states.clear
            @locks.clear
          end
        end

        private
          def lock_for(match_id)
            @monitor.synchronize { @locks[match_id] ||= Monitor.new }
          end

          def state_for(match)
            @monitor.synchronize do
              @states[match.id] ||= MatchState.new(match, rules: Spec.default_rules).tap(&:rehydrate!)
            end
          end

          # One sweeper for every match, not one timer per match, and not a flush on the
          # way out of each checkout.
          #
          # Debouncing inside checkout was the obvious thing and it is wrong: it can only
          # flush when the NEXT batch arrives, so a player who knocks a wall out and then
          # stops driving leaves that wall in memory indefinitely. The promise is that a
          # restart costs at most FLUSH_EVERY of damage, and only something running on its
          # own can keep it.
          #
          # Not started under test, where a write landing between two assertions is exactly
          # the kind of timing no test should have to reason about. The suite calls
          # flush_all! when it wants the rows.
          def sweeping!
            return if @sweeper || Rails.env.test?

            @monitor.synchronize do
              @sweeper ||= Concurrent::TimerTask.execute(execution_interval: FLUSH_EVERY) do
                ActiveRecord::Base.connection_pool.with_connection { flush_all! }
              end
            end
          end
      end
    end
  end
end
