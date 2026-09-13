module Game
  module Parts
    # Thrust along the chassis up-axis, so the driver can aim the burn by rotating the
    # truck. Burns the turbo bar continuously while held.
    class JumpJets < Part
      attr_reader :thrust, :drain_rate

      def initialize(offset:, size:, thrust:, drain_rate:, name: "jump_jets")
        super(name: name, offset: offset, size: size, damage_multiplier: 1.0)
        @thrust = thrust.to_f
        @drain_rate = drain_rate.to_f
      end

      # Returns the thrust to apply this step, or 0.0 when the bar cannot pay for it.
      def burn(turbo_bar, dt)
        return 0.0 unless turbo_bar.draw(drain_rate * dt.to_f)

        thrust
      end

      # Seconds of continuous burn a full bar buys.
      def burn_seconds(turbo_bar)
        return Float::INFINITY if drain_rate.zero?

        turbo_bar.capacity / drain_rate
      end

      def to_spec
        super.merge(thrust: thrust, drain_rate: drain_rate)
      end
    end
  end
end
