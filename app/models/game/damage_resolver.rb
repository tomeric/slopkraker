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
    attr_reader :damage_per_speed, :minimum_speed

    def initialize(damage_per_speed:, minimum_speed:)
      @damage_per_speed = damage_per_speed.to_f
      @minimum_speed = minimum_speed.to_f
    end

    # `part` is nil for a bare chassis hit. An unarmed part still does chassis damage,
    # it just earns no bonus. `material` is nil for anything without one -- today's crates
    # and pillars carry their own health and are unchanged by this.
    def resolve(part:, speed:, state: {}, material: nil, kind: :impact)
      excess = speed.to_f - minimum_speed
      return 0.0 if excess <= 0

      raw = excess * damage_per_speed * multiplier_for(part, state)
      return raw if material.nil?

      absorb(raw * material.multiplier_for(kind), material)
    end

    private
      def multiplier_for(part, state)
        return 1.0 unless part&.armed?(state)

        part.damage_multiplier
      end

      # Armour comes off after the multipliers, not before. Taking it off first would let
      # a big multiplier cancel armour out entirely, which is the opposite of what armour
      # is for: concrete should resist a fast bump no matter how good the blade is.
      def absorb(damage, material)
        [ damage - material.armour, 0.0 ].max
      end
  end
end
