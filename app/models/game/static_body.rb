module Game
  # Immovable arena geometry: the ground, the walls, the ramps. `kind` is what the
  # client keys its material off, and what damage reporting names when you hit it.
  class StaticBody
    attr_reader :name, :kind, :position, :size, :rotation, :colour, :friction, :restitution

    def initialize(name:, kind:, position:, size:, rotation: Quaternion.identity,
                   colour: "#8a8f98", friction: 1.0, restitution: 0.05)
      @name = name.to_s
      @kind = kind.to_s
      @position = position
      @size = size
      @rotation = rotation
      @colour = colour
      @friction = friction.to_f
      @restitution = restitution.to_f
    end

    def to_spec
      {
        name: name,
        kind: kind,
        position: position.to_a,
        size: size.to_a,
        rotation: rotation.to_a,
        colour: colour,
        friction: friction,
        restitution: restitution
      }
    end
  end
end
