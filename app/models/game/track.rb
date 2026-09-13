module Game
  # A closed circuit for testing how the vehicles feel: long enough to build speed, with
  # corners of genuinely different radii and real elevation change, so a drift can be
  # tried against a hairpin, a sweeper and a crest rather than empty floor.
  #
  # Deliberately unbarriered for now: running wide should cost you time, not end the
  # run, and drifting back on is half the fun.
  #
  # The centreline is a Catmull-Rom spline through control points, sampled into short
  # road slabs. Each slab is a box rotated to follow the spline in both yaw and pitch,
  # which is what gives the climbs and descents.
  class Track
    Spawn = Struct.new(:position, :yaw, keyword_init: true) do
      def to_spec = { position: position.to_a, yaw: yaw }
    end

    WIDTH = 16.0
    THICKNESS = 1.2
    KERB_WIDTH = 1.4
    SAMPLES_PER_SEGMENT = 9
    # The spline overshoots slightly below its control points; lift the whole circuit so
    # it sits on the ground rather than sinking into it.
    BASE_HEIGHT = 1.0
    # Slabs overlap slightly; without it the seams between them catch wheels.
    OVERLAP = 1.08

    # x, y, z. The y values are what create the climb up the back straight and the drop
    # through the final corners.
    CONTROL_POINTS = [
      [ -120.0,  0.0, -120.0 ],
      [  -20.0,  0.0, -145.0 ],
      [  95.0,   0.0, -120.0 ],
      [  140.0,  7.0,  -35.0 ],
      [  105.0, 12.0,   55.0 ],
      [   25.0,  6.0,  120.0 ],
      [  -65.0,  0.0,  135.0 ],
      [ -140.0,  0.0,   55.0 ],
      [ -135.0,  0.0,  -40.0 ]
    ].freeze

    def self.build
      new(centreline: sample(CONTROL_POINTS, SAMPLES_PER_SEGMENT))
    end

    def self.sample(points, per_segment)
      count = points.length

      count.times.flat_map do |i|
        p0 = points[(i - 1) % count]
        p1 = points[i]
        p2 = points[(i + 1) % count]
        p3 = points[(i + 2) % count]

        per_segment.times.map do |step|
          point = interpolate(p0, p1, p2, p3, step.to_f / per_segment)
          [ point[0], point[1] + BASE_HEIGHT, point[2] ]
        end
      end
    end

    def self.interpolate(p0, p1, p2, p3, t)
      t2 = t * t
      t3 = t2 * t

      (0..2).map do |axis|
        a, b, c, d = p0[axis], p1[axis], p2[axis], p3[axis]
        0.5 * ((2 * b) +
               (-a + c) * t +
               (2 * a - 5 * b + 4 * c - d) * t2 +
               (-a + 3 * b - 3 * c + d) * t3)
      end
    end

    attr_reader :centreline

    def initialize(centreline:)
      @centreline = centreline
    end

    def bodies
      centreline.each_with_index.flat_map do |point, index|
        nxt = centreline[(index + 1) % centreline.length]
        segment(point, nxt, index)
      end.compact
    end

    # Unit tangent at a centreline index, for placing things alongside the track.
    def tangent_at(index)
      from = centreline[index % centreline.length]
      to = centreline[(index + 1) % centreline.length]
      dx = to[0] - from[0]
      dz = to[2] - from[2]
      length = Math.sqrt(dx * dx + dz * dz)
      return [ 0.0, 1.0 ] if length.zero?

      [ dx / length, dz / length ]
    end

    # A point `offset` metres to the side of the racing line.
    def beside(index, offset)
      point = centreline[index % centreline.length]
      tx, tz = tangent_at(index)
      [ point[0] + tz * offset, point[1], point[2] - tx * offset ]
    end

    # Spread evenly around the lap. The heading matters as much as the position: dropped
    # in facing a fixed direction, a car simply drives off the circuit and flips.
    def spawns
      count = centreline.length

      4.times.map do |i|
        index = (i * count / 4) % count
        point = centreline[index]
        tx, tz = tangent_at(index)

        Spawn.new(
          position: Vector3.new(point[0], point[1] + 2.0, point[2]),
          yaw: Math.atan2(tx, tz)
        )
      end
    end

    private
      def segment(from, to, index)
        dx = to[0] - from[0]
        dy = to[1] - from[1]
        dz = to[2] - from[2]
        length = Math.sqrt(dx * dx + dy * dy + dz * dz)
        return nil if length < 0.01

        yaw = Math.atan2(dx, dz)
        # Negative pitch lifts the far end: a positive rotation about local X tips +Z down.
        pitch = -Math.asin([ [ dy / length, 1.0 ].min, -1.0 ].max)
        rotation = Quaternion.from_yaw_pitch(yaw, pitch)
        centre = Vector3.new((from[0] + to[0]) / 2, (from[1] + to[1]) / 2, (from[2] + to[2]) / 2)

        bodies = [
          StaticBody.new(
            name: "road_#{index}", kind: "road",
            position: centre,
            size: Vector3.new(WIDTH, THICKNESS, length * OVERLAP),
            rotation: rotation, colour: "#3f444b", friction: 1.15
          )
        ]

        # Perpendicular to the segment in the XZ plane.
        side_x = Math.cos(yaw)
        side_z = -Math.sin(yaw)

        [ 1, -1 ].each do |side|
          offset = (WIDTH / 2) + (KERB_WIDTH / 2)
          kerb_centre = Vector3.new(
            centre.x + side_x * offset * side,
            centre.y + 0.15,
            centre.z + side_z * offset * side
          )
          bodies << StaticBody.new(
            name: "kerb_#{index}_#{side}", kind: "kerb",
            position: kerb_centre,
            size: Vector3.new(KERB_WIDTH, THICKNESS, length * OVERLAP),
            rotation: rotation,
            colour: index.even? ? "#d94f3d" : "#eceff3",
            friction: 0.85
          )
        end

        bodies
      end
  end
end
