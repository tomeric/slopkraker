module Game
  # The one place damage formulas live. The client reports a physical impact; this
  # decides what it cost. Keeping it here means damage can be retuned without
  # touching a line of JavaScript.
  #
  # Damage used to be entirely a property of the attacker -- how fast, and with what part.
  # A world made of brick, glass and timber needs the other half: `material` and `kind`
  # say what was hit and how, so a window goes on contact and a concrete pier does not
  # care how fast you were going.
  #
  # Ported to game/damage.js. The two must change together.
  class DamageResolver
    attr_reader :damage_per_speed, :minimum_speed, :minimum_fraction, :spread

    # `spread` is not applied here -- what a hit does to the cells around it is the
    # building's business, not the formula's. It rides along so both sides read it from
    # the same rules block rather than each keeping their own number.
    def initialize(damage_per_speed:, minimum_speed:, minimum_fraction: 0.0, spread: 0.0)
      @damage_per_speed = damage_per_speed.to_f
      @minimum_speed = minimum_speed.to_f
      @minimum_fraction = minimum_fraction.to_f
      @spread = spread.to_f
    end

    # `part` is nil for a bare chassis hit. An unarmed part still does chassis damage,
    # it just earns no bonus. `material` is nil for anything without one.
    #
    # Hardness is subtracted after the multipliers, but never all the way to nothing: a
    # fixed fraction of every hit always lands. Without that floor, anything whose hardness
    # exceeds what a car can deliver is not merely tough but permanently immune, and a
    # player has no way to tell those two apart -- they just hit it forever and nothing
    # happens. The floor keeps "chip away at it" honest while leaving hardness in charge of
    # how long that takes.
    def resolve(part:, speed:, state: {}, material: nil, kind: :impact)
      excess = speed.to_f - minimum_speed
      return 0.0 if excess <= 0

      raw = excess * damage_per_speed * multiplier_for(part, state)
      return raw if material.nil?

      material.absorb(raw * material.multiplier_for(kind), minimum_fraction)
    end

    private
      def multiplier_for(part, state)
        return 1.0 unless part&.armed?(state)

        part.damage_multiplier
      end
  end
end
