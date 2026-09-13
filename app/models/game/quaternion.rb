module Game
  # Value object. Static bodies need real orientations (ramps are rotated boxes), and
  # the client wants them as [x, y, z, w] to hand straight to three.js and Rapier.
  class Quaternion
    attr_reader :x, :y, :z, :w

    def self.identity
      new(0, 0, 0, 1)
    end

    def self.from_axis_angle(axis, radians)
      ax, ay, az = axis.to_a
      length = Math.sqrt(ax * ax + ay * ay + az * az)
      return identity if length.zero?

      half = radians / 2.0
      scale = Math.sin(half) / length
      new(ax * scale, ay * scale, az * scale, Math.cos(half))
    end

    # Yaw about Y, then pitch about the resulting local X. Enough to aim a ramp.
    def self.from_yaw_pitch(yaw_radians, pitch_radians)
      from_axis_angle(Vector3.new(0, 1, 0), yaw_radians) *
        from_axis_angle(Vector3.new(1, 0, 0), pitch_radians)
    end

    def initialize(x, y, z, w)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
      @w = w.to_f
    end

    def *(other)
      self.class.new(
        w * other.x + x * other.w + y * other.z - z * other.y,
        w * other.y - x * other.z + y * other.w + z * other.x,
        w * other.z + x * other.y - y * other.x + z * other.w,
        w * other.w - x * other.x - y * other.y - z * other.z
      )
    end

    def to_a
      [ x, y, z, w ]
    end
    alias_method :to_spec, :to_a

    def ==(other)
      other.is_a?(Quaternion) && to_a == other.to_a
    end
  end
end
