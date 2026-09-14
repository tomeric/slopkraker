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
            # How many falling units may be in the air at once. A physics budget, and now
            # a measured one rather than the guess it started as. Measured on this machine
            # with a whole house airborne: creating all of it costs 5.3ms once, and
            # world.step goes from 0.03ms to 0.5ms mean, 1.6ms worst -- about 6% of a 120Hz
            # frame. The headless software renderer the suite runs on took it too. The old
            # value of 140 was low by roughly ten times.
            #
            # Grouped into slabs a house is about 356 units, so this covers a full collapse
            # with room for a second building beside it. What does not fit still falls back
            # to shattering where it stood, spread evenly through the structure by stride.
            max: 600,
            # How many cells a falling slab may span, as rows x cols of the surface grid.
            # This is the difference between a building coming apart and a cloud of
            # confetti: a metre cube tumbling reads as neither masonry nor debris, while a
            # storey-high wall section toppling reads as exactly what it is.
            #
            # Walls are three rows tall, so rows: 3 means a wall slab is full storey height
            # and cols: 4 makes it four metres long -- three of them to a twelve metre wall.
            # Measured over this house, 3x4 rectangles cover 1398 cells in 356 units. Going
            # coarser stops paying: 4x6 saves only another 49, because walls fragment around
            # their windows and gables around their clipped corners whatever the cap.
            chunk: { rows: 3, cols: 4 },
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
          },
          # How a heap on the ground is drawn. Only the look lives here: the grid, how
          # densely it is filled and how tall a heap is are constants in Building::Rubble,
          # because those decide piece_count -- and a client that disagreed about them
          # would be addressing different pieces than the server.
          rubble: {
            # How far a heap may sit from its cell's centre, as a share of the cell. Over
            # a half, so heaps are pushed well off their grid and INTO each other: rubble
            # that interpenetrates reads as one pile, where rubble that politely keeps to
            # its own square reads as forty objects. They are fixed colliders and never
            # move, so nothing pushes them apart again.
            jitter: 0.55,
            # How much of its cell a heap fills. Read from the constant rather than written
            # again: Building::Rubble computes how DEEP a heap is against this same number,
            # so a second copy that drifted would leave the client drawing heaps of a size
            # the server never sized.
            scale: Building::Rubble::SPREAD,
            # How many different lumps there are. Read from the constant for the same
            # reason scale is: the client builds one instanced pool per shape, and a
            # disagreement would leave heaps drawn from a pool nobody allocated.
            shapes: Building::Rubble::SHAPES,
            # How far a heap sinks into the ground, as a share of its own height. Rubble
            # settles INTO the ground it lands on; a lump resting exactly on the surface
            # reads as an object that was placed there.
            #
            # Never more than 0.65: a third of a heap has to stand proud or it stops being
            # something you have to get around. The range below keeps clear of that rather
            # than riding it.
            sink: [ 0.05, 0.45 ],
            # How far a heap leans off level. A heap is not a paving slab, and this is what
            # stops it reading as one -- it was the last thing making them look laid rather
            # than dropped.
            tilt: 0.28,
            # How sharply the pile falls away from its middle, as the exponent of a dome.
            #
            # This is what makes wreckage a PILE rather than a carpet, and it costs nothing:
            # the profile is normalised so that its mean over the heaps is exactly one, so
            # the same material is simply put where a pile actually puts it. On this house
            # the centre goes from 1.5m to about 3m and the edges thin to a third of a
            # metre -- which also leaves the perimeter more driveable than it was, because
            # the material moved inward off it.
            #
            # Higher is steeper. Measured on this house, against the nearest heap to the
            # middle rather than an idealised centre: 1.5 gives a 2.5m peak, 2.5 gives 3.0m,
            # 3.5 gives 3.2m and stops paying.
            falloff: 2.5,
            # What is left at the rim, as a share of the peak. The dome must never reach
            # zero: a heap of no height is an invisible piece with a degenerate collider,
            # something you can neither see nor drive over nor clear. The edge of a pile
            # still has debris on it, there is just not much -- about a third of a metre
            # here. It is also a lever on the whole shape, because raising it lifts the
            # MEAN and so flattens everything the peak is measured against.
            edge: 0.06,
            # How much heaps differ in size from one another. Wide, because real debris is
            # a range from slabs down to fragments, and heaps within a few percent of each
            # other read as a manufactured thing however irregular each one is.
            spread: 0.55
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
