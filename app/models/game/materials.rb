module Game
  # The material table. Every number a destructible thing behaves by is here, and the
  # whole table ships in the spec so the client can look one up by name without holding a
  # constant of its own.
  #
  # Health and hardness are calibrated against what a car can actually deliver. An impact
  # at 30 m/s is worth about 52 damage before multipliers, so hardness has to sit well
  # below that or a hit rounds to nothing and the wall reads as invincible rather than as
  # tough. The intended shape, per 1.5m cell:
  #
  # These are game numbers, not building-trade ones. The point is not that a brick wall
  # behaves like a brick wall; it is that a monster truck and a buggy can knock a house
  # down, and enjoy doing it. Everything here is therefore soft enough to give way to the
  # vehicles that actually exist.
  #
  # The ordering is what carries the character, not the absolute values: glass goes on
  # contact, plaster is barely there, brick gives way to any real hit, concrete takes a
  # few, steel is the stubborn one. Relative, not realistic.
  #
  #   at a gentle nudge      glass, plaster, roof tile
  #   at driving speed       timber, brick -- and with damage spread, a hole rather than a nick
  #   a few solid hits       concrete
  #   a determined effort    steel -- stubborn, never immovable
  #
  # Nothing is immune. A fraction of every hit lands however hard the thing is, so steel
  # is a very long job rather than an impossible one.
  module Materials
    TABLE = {
      # Ordinary wall. The default for anything that has to hold a roof up.
      brick: Material.new(
        name: :brick, colour: "#a8674a",
        health_per_m2: 4.0, density: 1800.0, hardness: 1.0,
        multipliers: { blade: 1.15, slam: 1.3 },
        fracture: { method: "voronoi", mode: "3D", fragments: 16, approximate: true },
        friction: 0.9,
        chunk: { size: [ 0.55, 0.28, 0.30 ], vary: 0.45, jitter: 0.30 }
      ),

      # Piers, lintels, anything that wants a rocket rather than a shove. The hardness is
      # what makes bumping it pointless however fast you are going.
      concrete: Material.new(
        name: :concrete, colour: "#9aa0a6",
        health_per_m2: 7.0, density: 2400.0, hardness: 3.0,
        multipliers: { impact: 0.85, blast: 1.25, slam: 1.2 },
        fracture: { method: "voronoi", mode: "3D", fragments: 24, impact_radius: 0.35 },
        friction: 0.95, roughness: 0.95,
        chunk: { size: [ 0.90, 0.35, 0.60 ], vary: 0.40, jitter: 0.25 }
      ),

      # Interior partitions. Barely structural, and it should feel that way to drive
      # through.
      plaster: Material.new(
        name: :plaster, colour: "#d8d2c6",
        health_per_m2: 1.2, density: 700.0,
        structural_weight: 0.35,
        multipliers: { impact: 1.3, blast: 1.4 },
        fracture: { method: "voronoi", mode: "2.5D", fragments: 12 },
        friction: 0.7,
        chunk: { size: [ 0.70, 0.08, 0.50 ], vary: 0.40, jitter: 0.20 }
      ),

      # Window frames, door leaves, roof structure. Splinters along the grain rather than
      # breaking into chunks, which is what the fracture planes are for.
      timber: Material.new(
        name: :timber, colour: "#8a5a2b",
        health_per_m2: 2.0, density: 600.0,
        structural_weight: 0.5,
        multipliers: { blade: 1.4, bull_bar: 1.3 },
        fracture: { method: "simple", planes: { x: false, y: true, z: false }, fragments: 10 },
        friction: 0.75,
        chunk: { size: [ 1.40, 0.14, 0.18 ], vary: 0.35, jitter: 0.08 }
      ),

      # Goes on anything touching it, holds nothing up, and shatters into shards that are
      # prismatic through the thickness rather than diced -- which is what 2.5D is for.
      glass: Material.new(
        name: :glass, colour: "#9fd8e6",
        health_per_m2: 0.4, density: 2500.0,
        structural_weight: 0.0,
        multipliers: { impact: 3.0, blast: 2.5, blade: 2.0, bull_bar: 2.0, slam: 2.0 },
        fracture: { method: "voronoi", mode: "2.5D", fragments: 22, project_along_normal: true },
        friction: 0.35, restitution: 0.1,
        opacity: 0.3, metalness: 0.1, roughness: 0.08,
        chunk: { size: [ 0.35, 0.03, 0.30 ], vary: 0.50, jitter: 0.50 }
      ),

      # Shears flat off a roof. 3D voronoi on something this thin would give absurd cubes.
      roof_tile: Material.new(
        name: :roof_tile, colour: "#8c3b2e",
        health_per_m2: 1.2, density: 1900.0,
        structural_weight: 0.2,
        multipliers: { impact: 1.4, blast: 1.3 },
        fracture: { method: "voronoi", mode: "2.5D", fragments: 8 },
        friction: 0.8,
        chunk: { size: [ 0.45, 0.05, 0.40 ], vary: 0.30, jitter: 0.20 }
      ),

      # Dents rather than fragments. Present so there is something that simply will not
      # break, which makes everything that does feel like a choice.
      steel: Material.new(
        name: :steel, colour: "#6d7480",
        health_per_m2: 8.0, density: 7800.0, hardness: 6.0,
        multipliers: { impact: 0.7, blast: 0.9 },
        fracture: { method: "none", fragments: 0 },
        friction: 0.6, restitution: 0.2,
        metalness: 0.85, roughness: 0.35,
        chunk: { size: [ 1.20, 0.15, 0.15 ], vary: 0.30, jitter: 0.05 }
      ),

      # What a building becomes once it has finished falling down: the dust and mortar its
      # own chunks sit in. A heap is drawn as a lump of THIS with chunks of brick, timber
      # and tile in and on it, so the colour is a neutral grey-brown those read against
      # rather than a colour of its own. Light and weak, because a pile is an errand rather
      # than an obstacle. It has no chunk: it is what the chunks lie in.
      #
      # structural_weight is zero and must stay zero. Rubble is generated BY a collapse, so
      # anything that let it hold weight up would let a building be held up by its own
      # wreckage.
      rubble: Material.new(
        name: :rubble, colour: "#7d7569",
        health_per_m2: 2.5, density: 400.0,
        structural_weight: 0.0,
        multipliers: { impact: 1.3, blast: 1.5, blade: 1.4, bull_bar: 1.4, slam: 1.2 },
        fracture: { method: "voronoi", mode: "2.5D", fragments: 8 },
        friction: 0.9, restitution: 0.0,
        roughness: 0.95
      ),

      # A hole that is already there: a doorway, the clipped corner of a gable. It occupies
      # a piece index so the arithmetic stays uniform, but has no body, no mesh and nothing
      # to break. Without it, every cull would have to happen identically in Ruby and in
      # JavaScript.
      void: Material.new(
        name: :void, colour: "#000000",
        health_per_m2: 0.0, density: 0.0,
        structural_weight: 0.0,
        fracture: { method: "none", fragments: 0 }
      )
    }.freeze

    def self.fetch(name)
      TABLE.fetch(name.to_sym)
    end

    def self.names
      TABLE.keys
    end

    # Symbol keys, like the rest of the spec: JSON stringifies them on the way out, and
    # keeping them symbols means the payload can be read the same way everywhere in Ruby.
    def self.to_spec
      TABLE.transform_values(&:to_spec)
    end
  end
end
