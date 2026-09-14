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
      @flushed_at = {}

      class << self
        # Yields the match's state with nobody else inside it. A batch has to land whole:
        # two threads interleaving inside one would each read the health of a piece the
        # other was about to break.
        def checkout(match)
          lock_for(match.id).synchronize do
            state = state_for(match)
            result = yield state
            flush_if_due(match.id, state)
            result
          end
        end

        # Last one out writes the wreckage down. Everything after this point comes back
        # from the rows rather than from memory.
        def release(match)
          lock_for(match.id).synchronize do
            state = @monitor.synchronize { @states.delete(match.id) }
            state&.flush!
            @monitor.synchronize { @flushed_at.delete(match.id) }
          end
          @monitor.synchronize { @locks.delete(match.id) }
        end

        # Drops everything without writing it down. A test hook, and only that -- a real
        # release always flushes first.
        def reset!
          @monitor.synchronize do
            @states.clear
            @locks.clear
            @flushed_at.clear
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

          # Debounced rather than scheduled. A timer thread per match is a thread per match
          # to own and shut down, and the only moment a flush is worth anything is just
          # after something changed -- which is exactly when a batch has come through here.
          def flush_if_due(match_id, state)
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            last = @monitor.synchronize { @flushed_at[match_id] }
            return if last && now - last < FLUSH_EVERY

            state.flush!
            @monitor.synchronize { @flushed_at[match_id] = now }
          end
      end
    end
  end
end
