module Game
  # What a thing is made of, and therefore how it behaves when something hits it.
  #
  # Until now damage was purely a property of the attacker: DamageResolver asked how fast
  # you were going and what part connected, and never what you connected with. A world
  # made of brick, glass and timber needs the other half of that -- a rocket should go
  # through a window and bounce off a concrete pier.
  #
  # Every number here is tuning, so it lives in Ruby and ships in the spec. The client
  # looks materials up by name and holds no constants of its own.
  class Material
    # Damage kinds a material can resist or yield to differently. Glass barely notices a
    # blast wave but shatters if anything touches it; concrete is the other way round.
    KINDS = %i[impact blast blade bull_bar slam].freeze

    # What the client knows how to paint. Ruby's list and looks.js's PATTERNS are the same
    # list, and materials_test holds every material's look to this one.
    PATTERNS = %w[brick tiles planks plaster concrete glass leaves].freeze

    attr_reader :name, :health_per_m2, :density, :hardness, :structural_weight,
                :multipliers, :fracture, :colour, :friction, :restitution,
                :opacity, :metalness, :roughness, :chunk, :toll, :look, :role

    def initialize(name:, health_per_m2:, density:, colour:,
                   hardness: 0.0, structural_weight: 1.0, multipliers: {}, fracture: {},
                   friction: 0.8, restitution: 0.05,
                   opacity: 1.0, metalness: 0.05, roughness: 0.85, chunk: nil, toll: 1.0,
                   look: nil, role: nil)
      @name = name.to_sym
      @health_per_m2 = health_per_m2.to_f
      @density = density.to_f
      @hardness = hardness.to_f
      @structural_weight = structural_weight.to_f
      @multipliers = KINDS.index_with { |kind| (multipliers[kind] || 1.0).to_f }.freeze
      @fracture = fracture.freeze
      @colour = colour
      @friction = friction.to_f
      @restitution = restitution.to_f
      # How it looks, which is tuning like everything else here. A pane that is not
      # see-through is not a pane, and a hole in a wall only reads as one if you can see
      # through it into the room behind.
      @opacity = opacity.to_f
      @metalness = metalness.to_f
      @roughness = roughness.to_f
      # What a broken chunk of this looks like once it is lying in a heap: a mean size on
      # each axis in metres, how much that varies, and how far off a box the shape is.
      # Local Y is the THICKNESS, so a plank and a tile lie flat and a brick is a block.
      # Nil for anything that is never a chunk -- a hole, and the heap itself.
      @chunk = chunk&.transform_keys(&:to_sym)&.freeze
      # What breaking a cell of this costs the car that broke it, as a share of the health
      # it destroyed. A car that breaks a fixed piece is given back the speed the piece was
      # not worth; a wall is worth all of its health, because it has to be punched through,
      # while loose wreckage gives way and is worth a fraction. One for everything solid.
      @toll = toll.to_f
      # How a surface of this is DRAWN: which pattern, the size of its units in metres,
      # how wide and how dark the joints are, how much one unit differs from the next,
      # how deep the relief reads, and the albedo's base in value space -- light and nearly
      # neutral, because the hue is the palette's (Game::Palettes) and is applied per
      # instance. Nil for anything drawn flat: steel, which is a reflection; dust, which is
      # a shape; void, which is nothing.
      @look = look&.transform_keys(&:to_sym)&.freeze
      # Which palette colour a piece of this takes, or nil for its own colour. A brick wall
      # is coloured by the building's `brick`, its tiles by `roof_tile`, a door by `door`.
      @role = role&.to_sym
      freeze
    end

    # How much of a hit this simply shrugs off. Subtracted after the multipliers, so a
    # good part cannot cancel it out -- concrete should not care how sharp the blade is.
    def absorb(damage, floor_fraction)
      [ damage - hardness, damage * floor_fraction ].max
    end

    def multiplier_for(kind)
      multipliers.fetch(kind.to_sym, 1.0)
    end

    # Rounded HERE and nowhere else. This number is shipped to the client in the spec and
    # recomputed by the server when a hit lands, and the two have to be identical to the
    # last digit or a client breaks a piece the server still holds standing. Three
    # decimals is a thousandth of a hit point.
    def health_for(area, thickness)
      (health_per_m2 * area * thickness_factor(thickness)).round(3)
    end

    def mass_for(area, thickness)
      (density * area * thickness).round(3)
    end

    # A thicker wall is tougher, but not in proportion: one twice as thick is not twice as
    # hard to breach, because what fails is the face being punched through rather than the
    # whole volume resisting at once.
    def thickness_factor(thickness)
      Math.sqrt(thickness / 0.25)
    end

    # Glass and empty doorways hold nothing up. Used by the collapse rule, which weighs
    # what is still standing rather than counting it.
    def structural?
      structural_weight.positive?
    end

    def to_spec
      {
        name: name.to_s,
        health_per_m2: health_per_m2,
        density: density,
        hardness: hardness,
        structural_weight: structural_weight,
        multipliers: multipliers.transform_keys(&:to_s),
        fracture: fracture,
        colour: colour,
        friction: friction,
        restitution: restitution,
        opacity: opacity,
        metalness: metalness,
        roughness: roughness,
        chunk: chunk,
        toll: toll,
        look: look,
        role: role&.to_s
      }
    end
  end
end
