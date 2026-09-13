module Game
  # Not a building -- just enough to feel the blade, the bull bar and a rocket land
  # while the arena stays otherwise empty. Breaks into debris past its threshold.
  class DestructibleProp
    attr_reader :name, :kind, :position, :size, :rotation, :mass, :health, :debris_count, :colour

    def initialize(name:, kind:, position:, size:, mass:, health:,
                   rotation: Quaternion.identity, debris_count: 6, colour: "#b5651d")
      @name = name.to_s
      @kind = kind.to_s
      @position = position
      @size = size
      @rotation = rotation
      @mass = mass.to_f
      @health = health.to_f
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
        debris_count: debris_count,
        colour: colour
      }
    end
  end
end
