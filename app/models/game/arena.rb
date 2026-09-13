module Game
  # An enclosed box of ground with ramps to launch off and a handful of props to break.
  # Deliberately empty otherwise: this phase is about how the vehicles feel, and an
  # uncluttered arena is the fixture for that.
  class Arena
    SIZE = 380.0
    WALL_HEIGHT = 12.0
    WALL_THICKNESS = 2.0

    attr_reader :name, :gravity, :bodies, :props, :spawns, :track

    def self.build
      circuit = Track.build

      new(
        name: "Test Arena",
        gravity: Vector3.new(0, -9.81, 0),
        bodies: [ ground, *walls, *ramps, *circuit.bodies ],
        props: props(circuit),
        # Spawn on the circuit -- the track is the point of the arena now.
        spawns: circuit.spawns,
        track: circuit
      )
    end

    def self.ground
      StaticBody.new(
        name: "ground", kind: "ground",
        position: Vector3.new(0, -0.5, 0),
        size: Vector3.new(SIZE, 1.0, SIZE),
        colour: "#4a5159", friction: 1.1
      )
    end

    def self.walls
      half = SIZE / 2.0
      y = WALL_HEIGHT / 2.0

      [
        [ "wall_north", Vector3.new(0, y, half), Vector3.new(SIZE, WALL_HEIGHT, WALL_THICKNESS) ],
        [ "wall_south", Vector3.new(0, y, -half), Vector3.new(SIZE, WALL_HEIGHT, WALL_THICKNESS) ],
        [ "wall_east",  Vector3.new(half, y, 0), Vector3.new(WALL_THICKNESS, WALL_HEIGHT, SIZE) ],
        [ "wall_west",  Vector3.new(-half, y, 0), Vector3.new(WALL_THICKNESS, WALL_HEIGHT, SIZE) ]
      ].map do |name, position, size|
        StaticBody.new(name: name, kind: "wall", position: position, size: size,
                       colour: "#33383f", friction: 0.6)
      end
    end

    # A spread of angles so there is something to test squat, launch and landing against:
    # a gentle roller, a mid kicker, a steep launcher and a pair to straddle.
    def self.ramps
      [
        [ "ramp_gentle",      0.0,   30.0, 18.0, 24.0, 12.0,  0.0 ],
        [ "ramp_kicker",    -45.0,    0.0, 24.0, 10.0, 26.0, 90.0 ],
        [ "ramp_steep",      50.0,  -30.0, 12.0,  9.0, 34.0,  0.0 ],
        [ "ramp_twin_left", -16.0,  -55.0,  9.0, 14.0, 20.0,  0.0 ],
        [ "ramp_twin_right", 16.0,  -55.0,  9.0, 14.0, 20.0,  0.0 ],
        [ "ramp_long",       60.0,   45.0, 20.0, 34.0, 10.0, 30.0 ],
        [ "ramp_launch",    -60.0,   55.0, 14.0, 18.0, 30.0, -25.0 ]
      ].map do |name, x, z, width, length, degrees, yaw|
        ramp(name: name, x: x, z: z, width: width, length: length, degrees: degrees, yaw_degrees: yaw)
      end
    end

    def self.ramp(name:, x:, z:, width:, length:, degrees:, yaw_degrees: 0.0)
      pitch = -degrees * Math::PI / 180.0
      thickness = 1.0
      # Lift the centre so the low edge meets the ground and the rest buries itself.
      y = (length * Math.sin(degrees * Math::PI / 180.0)) / 2.0 - 0.25

      StaticBody.new(
        name: name, kind: "ramp",
        position: Vector3.new(x, y, z),
        size: Vector3.new(width, thickness, length),
        rotation: Quaternion.from_yaw_pitch(yaw_degrees * Math::PI / 180.0, pitch),
        colour: "#6b7280", friction: 1.0
      )
    end

    CRATE_SIZE = 1.5

    def self.props(circuit)
      trackside(circuit) + infield
    end

    # Stacks and pillars placed along the racing line so there is something to aim at
    # while testing how a drift or a blade hit actually lands.
    def self.trackside(circuit)
      props = []
      total = circuit.centreline.length

      # Stacks straddling the line at intervals around the lap.
      [ 6, 20, 34, 48, 62, 74 ].each_with_index do |index, n|
        [ -4.5, 4.5 ].each_with_index do |offset, side|
          x, y, z = circuit.beside(index, offset)
          props.concat(crate_stack("track_stack_#{n}_#{side}", x, z, base_y: y + 0.2, height: 3))
        end
      end

      # Pillars just off the kerb: clip one and it topples rather than stopping you dead.
      [ 13, 27, 41, 55, 69 ].each_with_index do |index, n|
        [ -11.0, 11.0 ].each_with_index do |offset, side|
          x, y, z = circuit.beside(index, offset)
          props << DestructibleProp.new(
            name: "track_pillar_#{n}_#{side}", kind: "pillar",
            position: Vector3.new(x, y + 2.2, z),
            size: Vector3.new(1.0, 4.4, 1.0),
            # Light enough to topple on contact rather than behave like a wall.
            mass: 90.0, health: 200.0, debris_count: 8, colour: "#9aa0a6"
          )
        end
      end

      props
    end

    def self.infield
      props = []

      # Clusters of stacks to plough through.
      [
        [ -20.0, 10.0, 4 ], [ -16.0, 10.0, 3 ], [ -18.0, 13.5, 2 ],
        [ 20.0, 14.0, 4 ], [ 24.0, 14.0, 3 ], [ 22.0, 17.5, 2 ],
        [ 0.0, -18.0, 5 ], [ 4.0, -18.0, 3 ], [ -4.0, -18.0, 3 ],
        [ -70.0, -20.0, 4 ], [ -66.0, -20.0, 3 ],
        [ 75.0, 10.0, 4 ], [ 79.0, 10.0, 3 ],
        [ -35.0, 75.0, 4 ], [ -31.0, 75.0, 3 ],
        [ 40.0, -80.0, 5 ], [ 44.0, -80.0, 3 ]
      ].each_with_index do |(x, z, height), i|
        props.concat(crate_stack("stack_#{i}", x, z, base_y: 0.0, height: height))
      end

      # A colonnade of free-standing pillars, deliberately light.
      pillars = [
        [ -40.0, -10.0 ], [ 40.0, -10.0 ], [ -40.0, 20.0 ], [ 40.0, 20.0 ],
        [ -85.0, 40.0 ], [ 85.0, 40.0 ], [ -85.0, -55.0 ], [ 85.0, -55.0 ],
        [ 0.0, 70.0 ], [ 0.0, -95.0 ], [ -55.0, -60.0 ], [ 55.0, 60.0 ],
        [ -20.0, 45.0 ], [ 20.0, 45.0 ], [ -20.0, -45.0 ], [ 20.0, -45.0 ]
      ]
      pillars.each_with_index do |(x, z), i|
        props << DestructibleProp.new(
          name: "pillar_#{i}", kind: "pillar",
          position: Vector3.new(x, 2.5, z),
          size: Vector3.new(1.2, 5.0, 1.2),
          mass: 120.0, health: 240.0, debris_count: 8, colour: "#9aa0a6"
        )
      end

      props
    end

    # Crates stacked squarely on top of one another, so hitting the bottom one brings the
    # whole pile down.
    def self.crate_stack(name, x, z, base_y: 0.0, height: 3)
      height.times.map do |level|
        DestructibleProp.new(
          name: "#{name}_#{level}",
          kind: "crate",
          position: Vector3.new(x, base_y + (CRATE_SIZE / 2) + level * CRATE_SIZE, z),
          size: Vector3.new(CRATE_SIZE, CRATE_SIZE, CRATE_SIZE),
          mass: 55.0, health: 110.0, debris_count: 6, colour: "#b5651d"
        )
      end
    end

    def initialize(name:, gravity:, bodies:, props:, spawns:, track: nil)
      @name = name
      @gravity = gravity
      @bodies = bodies
      @props = props
      @spawns = spawns
      @track = track
    end

    def to_spec
      {
        name: name,
        size: SIZE,
        gravity: gravity.to_a,
        bodies: bodies.map(&:to_spec),
        props: props.map(&:to_spec),
        spawns: spawns.map(&:to_spec)
      }
    end
  end
end
