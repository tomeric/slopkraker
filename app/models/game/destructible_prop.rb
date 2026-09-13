module Game
  # Not a building -- just enough to feel the blade, the bull bar and a rocket land
  # while the arena stays otherwise empty. Breaks into debris past its threshold.
  class DestructibleProp
    attr_reader :name, :kind, :position, :size, :rotation, :mass, :health, :hardness,
                :debris_count, :colour

    def initialize(name:, kind:, position:, size:, mass:, health:, hardness: 0.0,
                   rotation: Quaternion.identity, debris_count: 6, colour: "#b5651d")
      @name = name.to_s
      @kind = kind.to_s
      @position = position
      @size = size
      @rotation = rotation
      @mass = mass.to_f
      @health = health.to_f
      # How much of a hit this shrugs off, the same way a material does. Zero for a
      # crate: a crate is a box of air and should break like one.
      @hardness = hardness.to_f
      @debris_count = debris_count.to_i
      @colour = colour
    end

    def to_spec
      {
        name: name,
        kind: kind,
        position: position.to_a,
        size: size.to_a,
        rotation: rotation.to_a,
        mass: mass,
        health: health,
        hardness: hardness,
        debris_count: debris_count,
        colour: colour
      }
    end
  end
end
