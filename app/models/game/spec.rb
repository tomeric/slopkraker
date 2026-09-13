module Game
  # Composition root and the single source of truth handed to the client.
  #
  # `version` digests the whole payload. Two clients running different tuning would
  # desync in a way that reads like a netcode bug, so the version makes staleness
  # detectable instead of mysterious.
  #
  # Named Spec rather than World because there is now a ::World record holding the
  # persistent map. Inside `module Game` a bare `World` would resolve here, so a model
  # named the same thing would be a very long-fused bug: everything would work until
  # something under Game:: meant to reach the record and silently reached this instead.
  class Spec
    PHYSICS_HZ = 120
    SNAPSHOT_HZ = 20

    attr_reader :arena, :vehicles, :rules, :input

    # A world record's scene, plus the tuning every world shares.
    def self.for(world)
      build(scene: world.scene)
    end

    def self.build(scene:)
      new(
        arena: scene,
        vehicles: {
          monster_truck: Vehicles::MonsterTruck.build,
          buggy: Vehicles::Buggy.build
        },
        rules: default_rules,
        input: InputBindings.build
      )
    end

    def self.default_rules
      {
        damage: {
          damage_per_speed: 2.0,
          minimum_speed: 4.0
        },
        impact_force_threshold: 2000.0,
        # How long the debug overlay holds a hit readout before returning to live values.
        damage_flash: 1.1,
        physics_hz: PHYSICS_HZ,
        max_substeps: 5,
        snapshot_hz: SNAPSHOT_HZ,
        interpolation_delay: 0.1,
        respawn_height: 2.0
      }
    end

    def initialize(arena:, vehicles:, rules:, input:)
      @arena = arena
      @vehicles = vehicles
      @rules = rules
      @input = input
    end

    def damage_resolver
      DamageResolver.new(**rules.fetch(:damage))
    end

    def vehicle(key)
      vehicles.fetch(key.to_sym)
    end

    def to_spec
      payload = {
        arena: arena.to_spec,
        vehicles: vehicles.transform_values(&:to_spec),
        # The whole table, inline. Every surface references a material by name, and the
        # first one can arrive before any other fetch resolves.
        materials: Materials.to_spec,
        rules: rules,
        input: input.to_spec
      }

      payload.merge(version: digest_of(payload))
    end

    private
      def digest_of(payload)
        Digest::SHA256.hexdigest(JSON.generate(payload))[0, 12]
      end
  end
end
