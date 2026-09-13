module Game
  module Parts
    # Fires in a slightly upward arc from the muzzle. Cooldown is a hard floor; the
    # turbo bar is the ammo supply, so boosting and shooting compete.
    #
    # `recoil` is the impulse the shot puts back into the car, in newton-seconds. It is
    # applied along the shot rather than along the chassis, so firing while sideways in a
    # drift shoves you sideways.
    class RocketLauncher < Part
      attr_reader :cooldown, :ammo_cost, :launch_angle, :recoil, :rocket

      def initialize(offset:, size:, cooldown:, ammo_cost:, launch_angle:, recoil:, rocket:,
                     name: "rocket_launcher")
        super(name: name, offset: offset, size: size, damage_multiplier: 1.0)
        @cooldown = cooldown.to_f
        @ammo_cost = ammo_cost.to_f
        @launch_angle = launch_angle.to_f
        @recoil = recoil.to_f
        @rocket = rocket
        @since_fired = Float::INFINITY
      end

      def ready?
        @since_fired >= cooldown
      end

      # Returns false without touching the bar when the shot is refused.
      def fire(turbo_bar)
        return false unless ready?
        return false unless turbo_bar.draw(ammo_cost)

        @since_fired = 0.0
        true
      end

      def update(dt)
        @since_fired += dt.to_f
      end

      def to_spec
        super.merge(
          cooldown: cooldown,
          ammo_cost: ammo_cost,
          launch_angle: launch_angle,
          recoil: recoil,
          rocket: rocket.to_spec
        )
      end
    end
  end
end
