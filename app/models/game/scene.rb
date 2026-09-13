module Game
  # What the client is handed to build a world out of: the gravity it runs under, the
  # fixed geometry, the things that can be broken, and where players start.
  #
  # Replaces Game::Arena, which composed the same payload from hardcoded class methods.
  # The shape on the wire is unchanged -- the client still reads spec.arena.{gravity,
  # bodies, props, spawns} -- but it is now assembled from World rows rather than written
  # out longhand, so there can be more than one of them and they can outlive a request.
  #
  # Nothing here touches the database. A World builds a Scene; a Scene never looks a
  # World up.
  class Scene
    attr_reader :name, :gravity, :bodies, :props, :buildings, :spawns, :bounds

    def initialize(name:, gravity:, bodies: [], props: [], buildings: [], spawns: [], bounds: nil)
      @name = name
      @gravity = gravity
      @bodies = bodies
      @props = props
      @buildings = buildings
      @spawns = spawns
      @bounds = bounds
    end

    def to_spec
      {
        name: name,
        gravity: gravity.to_a,
        bounds: bounds,
        bodies: bodies.map(&:to_spec),
        props: props.map(&:to_spec),
        # Surfaces, not pieces. Twenty or so of these describe what would otherwise be
        # two hundred and fifty boxes, and the client expands the grid itself.
        buildings: buildings,
        spawns: spawns.map(&:to_spec)
      }
    end
  end

  # Where a player starts, and which way they are pointed. Yaw matters: a spawn facing a
  # wall is a spawn nobody can drive out of.
  Spawn = Struct.new(:position, :yaw, keyword_init: true) do
    def to_spec
      { position: position.to_a, yaw: yaw.to_f }
    end
  end
end
