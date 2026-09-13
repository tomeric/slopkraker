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

    attr_reader :name, :health_per_m2, :density, :hardness, :structural_weight,
                :multipliers, :fracture, :colour, :friction, :restitution,
                :opacity, :metalness, :roughness

    def initialize(name:, health_per_m2:, density:, colour:,
                   hardness: 0.0, structural_weight: 1.0, multipliers: {}, fracture: {},
                   friction: 0.8, restitution: 0.05,
                   opacity: 1.0, metalness: 0.05, roughness: 0.85)
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

    # A cell's own health and mass, from its area and how thick it is. Computed here and
    # shipped once per surface rather than once per cell -- a wall is a grid of identical
    # cells, so repeating the number for each of them is pure payload.
    def health_for(area, thickness)
      health_per_m2 * area * thickness_factor(thickness)
    end

    def mass_for(area, thickness)
      density * area * thickness
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
        roughness: roughness
      }
    end
  end
end
