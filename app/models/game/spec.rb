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
            # TWO budgets, because they answer different questions, and a single number
            # answering both is what let a street over-subscribe the air in silence.
            #
            # `per_building` is what ONE collapse may put up: the stride budget, the thing
            # that decides how coarsely a house comes apart. `max` is the global ceiling on
            # live bodies, which is a physics cost and nothing to do with any one building.
            # While one house existed anywhere they were indistinguishable, so `capacity`
            # returned the ceiling and every collapse read it as though the whole of it were
            # free. Measured on the street: three houses condemned together promise 749
            # slabs against a ceiling of 600, and the 149 that did not fit used to be taken
            # out of the air -- from the house that was ALREADY FALLING, mid-descent,
            # throwing its shards in the sky and reporting home that it had landed.
            #
            # The largest house on the street tiles to 397 slabs, so 450 lets any of them
            # fall whole with room over.
            per_building: 450,
            # Measured on this machine, on the headless software renderer the suite runs
            # on, sampling world.step against what was in the air at the time: about a
            # thousand slabs costs 0.571ms mean / 1.1ms worst, which is 7% of a 120Hz
            # frame and squares with the 6% the old value of 600 was measured at. Twelve
            # hundred costs 1.2ms mean. Past that it stops being free -- the whole street
            # airborne at 1700 was the first reading where the frame visibly gave way.
            #
            # So: three of the largest houses at once, or six ordinary ones, each falling
            # in full. What does not fit still falls back to shattering where it stood,
            # spread evenly through the structure by stride.
            max: 1200,
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
            # Narrow, so neighbouring heaps settle to similar depths. A wide range put
            # adjacent lumps at randomly different heights, and they stepped against each
            # other instead of running together into one mass.
            sink: [ 0.1, 0.22 ],
            # How far a CHUNK leans off level. The base lump is level now, because the
            # collider is sized from it and forty leaned colliders are forty invisible
            # ramps; the lean moved to the chunks, which is where a heap reads as dropped
            # rather than laid.
            tilt: 0.28,
            # The pile's profile: a rounded cone, 1 - d to this power, where d is how far out
            # a heap sits. A cone with a rounded top and not a bell, because a bell trails
            # off into a long thin foot and the pile ran out into a flat mat on every side
            # before it ended -- which read as flat edges. This keeps its bulk out toward
            # the rim and then drops, the way a heap of anything loose does.
            #
            # Normalised so that its mean over the heaps is exactly one, so the same
            # material is simply put where a pile puts it and the volume is conserved.
            #
            # Higher rounds the top more and holds the shoulders out further. Measured on
            # the worked example with the whole bulked volume kept: 1.4 peaks at 3.3m on
            # screen with a metre at eight tenths of the way out; 1.7 at 3.0m and 1.06m;
            # 2.0 at 2.8m and 1.1m. The height is a picture and not an obstacle -- the
            # wheel rays pass through heaps and the blade breaks whatever it meets.
            falloff: 1.7,
            # Where the peak sits, as a share of the grid's half-extent it may be pushed
            # off the middle, and how much the radius wobbles round it in two or three
            # lobes. Both drawn from the seed per building. A pile whose peak sat dead
            # centre with a perfectly elliptical contour read as a shape laid over the
            # house rather than a house that fell down.
            offset: 0.15,
            lobe: 0.2,
            # How much of its plan the lowest heap keeps, against a heap of mean height
            # keeping all of it. A rim heap twenty centimetres tall and three metres wide
            # is a plate, and a ring of plates is a flat edge; shrunk with its height it is
            # a small mound, and the fringe breaks up into scattered mounds instead. Only
            # the fringe shrinks -- see the reach invariant in spec_test -- because in the
            # body of the pile a gap is a pocket of air and at its edge a gap is the edge.
            rim: 0.6,
            # What is left at the rim, as a share of the peak. The dome must never reach
            # zero: a heap of no height is an invisible piece with a degenerate collider,
            # something you can neither see nor drive over nor clear. The edge of a pile
            # still has debris on it, there is just not much -- about a third of a metre
            # here. It is also a lever on the whole shape, because raising it lifts the
            # MEAN and so flattens everything the peak is measured against.
            edge: 0.06,
            # How much heaps differ in size from one another.
            #
            # BOUNDED BY THE GRID, and this is the whole of why a mound had pockets of air
            # in it. Heaps sit CELL apart and are CELL * SPREAD across, so a heap shrunk far
            # enough cannot reach the heaps beside it and leaves a hole however irregular it
            # is. At 0.55 the smallest was 1.43m on a 2m grid -- it could not touch anything.
            # There is a test for the invariant rather than for this number.
            spread: 0.25,
            # How far a heap's plan may depart from square, as a ratio applied to one
            # horizontal axis and divided out of the other so the ground it covers is
            # unchanged. BOUNDED BY THE SAME GRID as spread, and for the same reason: it
            # narrows an axis, so too much of it reaches under the spacing and reopens the
            # holes spread was tightened to close. The test covers both together.
            aspect: 0.15,
            # How many chunks of the building's own material sit in and on each heap. Fixed
            # per heap because the instanced pools are allocated once at boot and cannot
            # grow; rim heaps get the same number, smaller and centre heaps the same number,
            # larger. Twenty on forty-two heaps is under a thousand instances for a house,
            # spread over one pool per material.
            fragments: 20,
            # How long a revealed heap takes to rise out of the ground, in seconds. The
            # collider is there at once; only the drawing eases. Zero pops.
            rise: 0.45,
            # What clearing a heap does with its chunks: `keep` of them are left lying where
            # they were, settle onto the ground over `settle`, lie there for `linger`, then
            # fade out over `fade` while sinking away. `shards` more are thrown as debris in
            # their own materials, so the impact reads in the colours of what was hit. Both
            # are drawn from the heap's own chunks, so together they cannot exceed
            # `fragments`.
            shards: 2,
            remnants: {
              keep: 3,
              settle: 0.35,
              linger: 2.0,
              fade: 1.5
            }
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
        respawn_height: 2.0,
        # What happens to the small stuff -- the shards a break throws, the chunks a cleared
        # heap leaves lying -- when something bigger reaches it. None of it has a body, so
        # nothing in the physics ever touches it; it is swept by hand instead. A car reaching
        # a shard kicks it away and it is gone within `kicked_life`; a blast throws it
        # outward the same way. Without this a car parked in a debris field sat in shards
        # that ignored it, which reads as the shards being painted on.
        debris: {
          # How far beyond a chassis's own box a car reaches, in metres. Wider than the
          # bodywork so the wheels and the wake count.
          reach: 0.5,
          # The shove a kicked shard leaves with, plus this share of the car's own velocity
          # so debris flies ahead of a fast car rather than dropping beside it, and the lift
          # that makes it a kick rather than a slide.
          kick_speed: 5.0,
          kick_carry: 0.6,
          kick_lift: 3.0,
          # And from a blast, scaled by how far into the shell the shard sat.
          blast_speed: 12.0,
          blast_lift: 5.0,
          # How long a kicked shard has left, in seconds. Short: it is on its way out.
          kicked_life: 0.6,
          # How long a fresh shard or remnant is left alone, in seconds. The shards a blast
          # throws are born inside its own shell, and the chunks a heap leaves when the
          # truck ploughs it are born inside the truck's box; without this the blast swept
          # its own shards and the truck swept the very remnants that are meant to lie there
          # a moment. Longer than a blast takes to expand, and long enough for a fast truck
          # to have passed over what it just cleared.
          grace: 0.5
        }
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
