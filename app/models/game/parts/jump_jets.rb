module Game
  module Parts
    # Thrust along the chassis up-axis, so the driver can aim the burn by rotating the
    # truck. Burns the turbo bar continuously while held.
    #
    # `nozzles` are the visible boosters. They carry no physics -- thrust is one impulse at
    # the centre of mass -- but they are how the driver reads the attitude they are flying,
    # so the bias terms below have to agree with the chassis axes exactly:
    #
    #   forward = +Z, up = +Y, so right = forward x up = -X, and the driver's LEFT is +X.
    #
    # A nozzle underneath pushes its own corner UP. Steering right rolls the truck right by
    # lifting its left side, so the LEFT nozzles are the ones that burn: roll_bias +1 means
    # "burns harder as input.steer goes positive". input.pitch is +1 nose-down, and dropping
    # the nose raises the tail, so the REAR nozzles carry pitch_bias +1.
    #
    # The slam is the same thruster pointed the other way, hence the roof nozzle living
    # here too rather than in a part of its own.
    class JumpJets < Part
      attr_reader :thrust, :drain_rate, :flame, :nozzles

      def initialize(offset:, size:, thrust:, drain_rate:, flame: {}, nozzles: [], name: "jump_jets")
        super(name: name, offset: offset, size: size, damage_multiplier: 1.0)
        @thrust = thrust.to_f
        @drain_rate = drain_rate.to_f
        @flame = flame.symbolize_keys
        @nozzles = nozzles.map { normalise_nozzle(_1.symbolize_keys) }
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

      # Driven by the jets, so they answer the stick.
      def lift_nozzles
        nozzles.select { _1[:group] == "lift" }
      end

      # Driven by the slam ramp, which runs with air control switched off.
      def slam_nozzles
        nozzles.select { _1[:group] == "slam" }
      end

      def to_spec
        super.merge(thrust: thrust, drain_rate: drain_rate, flame: flame, nozzles: nozzles)
      end

      private
        def normalise_nozzle(nozzle)
          {
            name: nozzle[:name].to_s,
            group: nozzle[:group].to_s,
            offset: nozzle[:offset].to_a,
            direction: unit(nozzle[:direction]),
            radius: nozzle[:radius].to_f,
            flame_length: nozzle[:flame_length].to_f,
            roll_bias: nozzle[:roll_bias].to_f,
            pitch_bias: nozzle[:pitch_bias].to_f
          }
        end

        # The view aims the flame cone by rotating +Y onto this, which only behaves for a
        # unit vector -- so the length is taken out here rather than trusted from the spec.
        def unit(direction)
          x, y, z = direction.to_a
          length = Math.sqrt(x**2 + y**2 + z**2)
          return [ 0.0, 0.0, 0.0 ] if length.zero?

          [ x / length, y / length, z / length ]
        end
    end
  end
end
