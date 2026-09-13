module Game
  # The material table. Every number a destructible thing behaves by is here, and the
  # whole table ships in the spec so the client can look one up by name without holding a
  # constant of its own.
  #
  # The health numbers are calibrated against what already exists: a crate is 110 health
  # and a pillar 200, and an impact at 30 m/s is worth about 52 damage before multipliers.
  # So a pane of glass should go on any contact, a brick panel should take a few good
  # hits, and concrete should want a rocket.
  module Materials
    TABLE = {
      # Ordinary wall. The default for anything that has to hold a roof up.
      brick: Material.new(
        name: :brick, colour: "#a8674a",
        health_per_m2: 26.0, density: 1800.0, armour: 4.0,
        multipliers: { blade: 1.15, slam: 1.3 },
        fracture: { method: "voronoi", mode: "3D", fragments: 16, approximate: true },
        friction: 0.9
      ),

      # Piers, lintels, anything that wants a rocket rather than a shove. The armour is
      # what makes bumping it pointless however fast you are going.
      concrete: Material.new(
        name: :concrete, colour: "#9aa0a6",
        health_per_m2: 62.0, density: 2400.0, armour: 14.0,
        multipliers: { impact: 0.7, blast: 1.25, slam: 1.2 },
        fracture: { method: "voronoi", mode: "3D", fragments: 24, impact_radius: 0.35 },
        friction: 0.95, roughness: 0.95
      ),

      # Interior partitions. Barely structural, and it should feel that way to drive
      # through.
      plaster: Material.new(
        name: :plaster, colour: "#d8d2c6",
        health_per_m2: 9.0, density: 700.0,
        structural_weight: 0.35,
        multipliers: { impact: 1.3, blast: 1.4 },
        fracture: { method: "voronoi", mode: "2.5D", fragments: 12 },
        friction: 0.7
      ),

      # Window frames, door leaves, roof structure. Splinters along the grain rather than
      # breaking into chunks, which is what the fracture planes are for.
      timber: Material.new(
        name: :timber, colour: "#8a5a2b",
        health_per_m2: 14.0, density: 600.0,
        structural_weight: 0.5,
        multipliers: { blade: 1.4, bull_bar: 1.3 },
        fracture: { method: "simple", planes: { x: false, y: true, z: false }, fragments: 10 },
        friction: 0.75
      ),

      # Goes on anything touching it, holds nothing up, and shatters into shards that are
      # prismatic through the thickness rather than diced -- which is what 2.5D is for.
      glass: Material.new(
        name: :glass, colour: "#9fd8e6",
        health_per_m2: 1.5, density: 2500.0,
        structural_weight: 0.0,
        multipliers: { impact: 3.0, blast: 2.5, blade: 2.0, bull_bar: 2.0, slam: 2.0 },
        fracture: { method: "voronoi", mode: "2.5D", fragments: 22, project_along_normal: true },
        friction: 0.35, restitution: 0.1,
        opacity: 0.3, metalness: 0.1, roughness: 0.08
      ),

      # Shears flat off a roof. 3D voronoi on something this thin would give absurd cubes.
      roof_tile: Material.new(
        name: :roof_tile, colour: "#8c3b2e",
        health_per_m2: 6.0, density: 1900.0,
        structural_weight: 0.2,
        multipliers: { impact: 1.4, blast: 1.3 },
        fracture: { method: "voronoi", mode: "2.5D", fragments: 8 },
        friction: 0.8
      ),

      # Dents rather than fragments. Present so there is something that simply will not
      # break, which makes everything that does feel like a choice.
      steel: Material.new(
        name: :steel, colour: "#6d7480",
        health_per_m2: 140.0, density: 7800.0, armour: 30.0,
        multipliers: { impact: 0.5, blast: 0.8 },
        fracture: { method: "none", fragments: 0 },
        friction: 0.6, restitution: 0.2,
        metalness: 0.85, roughness: 0.35
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
