module Game
  # Rockets leave the rail slowly and wind up under their own thrust, so a shot with room
  # to run hits far harder than one fired point blank. Damage is therefore a function of
  # how fast the rocket is travelling when it lands, not a fixed number.
  class Rocket
    attr_reader :launch_speed, :max_speed, :acceleration, :mass, :radius, :lifetime,
                :gravity_scale, :blast_radius, :minimum_damage, :max_damage,
                :damage_per_speed, :colour

    def initialize(launch_speed:, max_speed:, acceleration:, mass:, radius:, lifetime:,
                   gravity_scale:, blast_radius:, minimum_damage:, max_damage:,
                   damage_per_speed:, colour: "#ff5a1f")
      @launch_speed = launch_speed.to_f
      @max_speed = max_speed.to_f
      @acceleration = acceleration.to_f
      @mass = mass.to_f
      @radius = radius.to_f
      @lifetime = lifetime.to_f
      @gravity_scale = gravity_scale.to_f
      @blast_radius = blast_radius.to_f
      @minimum_damage = minimum_damage.to_f
      @max_damage = max_damage.to_f
      @damage_per_speed = damage_per_speed.to_f
      @colour = colour
    end

    def damage_at(speed)
      (damage_per_speed * speed.to_f).clamp(minimum_damage, max_damage)
    end

    # Seconds of thrust before it tops out, ignoring drag and gravity.
    def spin_up_time
      return 0.0 if acceleration.zero?

      (max_speed - launch_speed) / acceleration
    end

    def to_spec
      {
        launch_speed: launch_speed,
        max_speed: max_speed,
        acceleration: acceleration,
        mass: mass,
        radius: radius,
        lifetime: lifetime,
        gravity_scale: gravity_scale,
        blast_radius: blast_radius,
        minimum_damage: minimum_damage,
        max_damage: max_damage,
        damage_per_speed: damage_per_speed,
        colour: colour
      }
    end
  end
end
