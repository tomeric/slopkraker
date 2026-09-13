module Game
  # A collider bolted to a vehicle that carries a damage profile: the blade, the bull
  # bar, the launcher, the jets. Subclasses add behaviour; the base carries placement
  # and the damage multiplier the resolver reads.
  class Part
    attr_reader :name, :offset, :size, :damage_multiplier

    def initialize(name:, offset:, size:, damage_multiplier: 1.0)
      @name = name.to_s
      @offset = offset
      @size = size
      @damage_multiplier = damage_multiplier.to_f
    end

    def kind
      self.class.name.demodulize.underscore
    end

    # Overridden by parts whose damage is conditional -- the bull bar only bites
    # mid-slide. `state` is the client's reported vehicle state at impact.
    def armed?(state = {})
      true
    end

    def to_spec
      {
        name: name,
        kind: kind,
        offset: offset.to_a,
        size: size.to_a,
        damage_multiplier: damage_multiplier
      }
    end
  end
end
