module Game
  # The one place damage formulas live. The client reports a physical impact; this
  # decides what it cost. Keeping it here means damage can be retuned without
  # touching a line of JavaScript.
  class DamageResolver
    attr_reader :damage_per_speed, :minimum_speed

    def initialize(damage_per_speed:, minimum_speed:)
      @damage_per_speed = damage_per_speed.to_f
      @minimum_speed = minimum_speed.to_f
    end

    # `part` is nil for a bare chassis hit. An unarmed part still does chassis damage,
    # it just earns no bonus.
    def resolve(part:, speed:, state: {})
      excess = speed.to_f - minimum_speed
      return 0.0 if excess <= 0

      excess * damage_per_speed * multiplier_for(part, state)
    end

    private
      def multiplier_for(part, state)
        return 1.0 unless part&.armed?(state)

        part.damage_multiplier
      end
  end
end
