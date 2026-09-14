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
          minimum_speed: 4.0,
          # The share of a hit that lands however hard the target is. Without it, anything
          # whose hardness exceeds what a car can deliver is permanently immune, which a
          # player cannot tell apart from a bug.
          minimum_fraction: 0.1,
          # What a hit does to the cells around the one it landed on. Without it a lethal
          # impact takes out one panel and leaves a nick, which reads as a car bouncing off
          # a wall rather than going through it.
          #
          # Lower than it was, because a hit now takes a whole block rather than a cell and
          # the block was already doing most of this work. At the old value one impact
          # cleared five blocks, which is most of a wall.
          spread: 0.45
        },
        # When a storey stops holding itself up. Server-side only -- Damage::Collapse says
        # why at length -- but the numbers live here with every other tuning number, so
        # retuning how easily a house comes down is one edit in Ruby.
        collapse: {
          # The share of a storey's load-bearing area that has to survive for it to keep
          # standing.
          threshold: 0.40,
          # How far the weight still standing on a storey may outrun the support still
          # holding it, each as a fraction of what the building started with. This is the
          # clause with the character in it: what condemns a storey is how much support
          # went with the walls you took out, measured against how much is still up there
          # needing carrying. Lower it and houses come down in a hurry; raise it and they
          # have to be gutted.
          safety_factor: 1.6,
          # What the falling storey does to the one it lands on, as a share of its mass.
          # Small on purpose: a pancake should finish a storey that is already going, and
          # bounce off one that is not.
          pancake_damage_fraction: 0.0015,
          # How a condemned piece comes down. Everything above this line is the server's
          # and runs nowhere else; everything below it is the client's, and is here for
          # the same reason every other number is -- so retuning how a house falls is an
          # edit in Ruby.
          #
          # A condemned piece used to be replaced by its shards in the frame it was
          # condemned, which reads as a building being deleted rather than falling down.
          # Now it gets a real body first, and throws those same shards when it lands.
          fall: {
            # How many pieces may be in the air at once. This is a physics budget, not a
            # look: a collapse can condemn a thousand cells, and a thousand dynamic bodies
            # arriving in one frame is a stall. What does not fit falls back to shattering
            # where it stood, and which pieces those are is spread evenly through the
            # structure -- so a big collapse is a house coming apart, not one wall falling
            # while the rest puffs away.
            max: 140,
            # How long a piece ignores what it touches. Without this nothing survives its
            # first frame: condemned panels start out flush against their neighbours and a
            # floor deck starts sitting on the wall-head below it, so the first contact
            # arrives before the piece has moved at all.
            arm: 0.12,
            # A backstop for a piece that lands on nothing -- thrown clear of the building
            # and still falling, or wedged somewhere it never resolves. Nothing may hold a
            # body forever.
            life: 6.0,
            # The outward shove and tumble a piece leaves with, so a storey comes apart
            # rather than descending like a lift.
            drift: 1.6,
            spin: 2.2,
            linear_damping: 0.05,
            angular_damping: 0.4,
            # Mass comes from the material's own density and the cell's real volume, which
            # makes a falling brick panel around half a tonne. Scale it here if that turns
            # out to shove the car harder than it should.
            density_scale: 1.0
          }
        },
        impact_force_threshold: 2000.0,
        # How long the debug overlay holds a hit readout before returning to live values.
        damage_flash: 1.1,
        physics_hz: PHYSICS_HZ,
        max_substeps: 5,
        snapshot_hz: SNAPSHOT_HZ,
        interpolation_delay: 0.1,
        # How long another player's car stays after it stops arriving.
        #
        # Leaving cannot be announced reliably: a browser closing a tab does not get to run
        # JavaScript on the way out, so the unsubscribe never reaches the server and it
        # falls back to noticing the dead socket -- measured at over twelve seconds. A
        # ghost car sitting in the road that long is worse than one that vanishes a moment
        # early, so silence is what counts as gone. The channel's own `leave` message is
        # still honoured when it does arrive; it is the fast path, not the mechanism.
        remote_timeout: 3.0,
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
