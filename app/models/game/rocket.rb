module Game
  # Rockets lob out of the launcher under their own momentum, shedding speed, and only
  # light the motor near the apex of that first arc -- which is what gives the flight two
  # distinct arcs rather than one flat dart. Damage is a function of how fast the rocket
  # is travelling when it lands, so a shot with room to run hits far harder than one
  # fired point blank.
  class Rocket
    attr_reader :launch_speed, :mass, :radius, :lifetime, :minimum_damage, :max_damage,
                :damage_per_speed, :colour, :flight, :explosion

    def initialize(launch_speed:, mass:, radius:, lifetime:, minimum_damage:, max_damage:,
                   damage_per_speed:, flight:, explosion:, colour: "#ff5a1f")
      @launch_speed = launch_speed.to_f
      @mass = mass.to_f
      @radius = radius.to_f
      @lifetime = lifetime.to_f
      @minimum_damage = minimum_damage.to_f
      @max_damage = max_damage.to_f
      @damage_per_speed = damage_per_speed.to_f
      @flight = flight.deep_symbolize_keys
      @explosion = explosion
      @colour = colour
    end

    # Unpowered, arcing, giving up speed to drag.
    def coast
      flight.fetch(:coast)
    end

    # Motor lit: accelerating along its own heading, and arcing far less because of it.
    def thrust
      flight.fetch(:thrust)
    end

    def damage_at(speed)
      (damage_per_speed * speed.to_f).clamp(minimum_damage, max_damage)
    end

    # What the rocket is doing while it coasts: bleeding off launch speed, never past a
    # standstill.
    def coast_speed_at(elapsed)
      (launch_speed - coast.fetch(:drag).to_f * elapsed.to_f).clamp(0.0, launch_speed)
    end

    # Seconds of thrust before it tops out, ignoring drag and gravity.
    def spin_up_time
      acceleration = thrust.fetch(:acceleration).to_f
      return 0.0 if acceleration.zero?

      (thrust.fetch(:max_speed).to_f - launch_speed) / acceleration
    end

    def to_spec
      {
        launch_speed: launch_speed,
        mass: mass,
        radius: radius,
        lifetime: lifetime,
        minimum_damage: minimum_damage,
        max_damage: max_damage,
        damage_per_speed: damage_per_speed,
        colour: colour,
        flight: flight,
        explosion: explosion.to_spec
      }
    end
  end
end
