module Game
  # Value object. Exists so vehicle definitions read as geometry rather than as
  # anonymous three-element arrays; serialises back down to [x, y, z] for the client.
  class Vector3
    attr_reader :x, :y, :z

    def self.[](array)
      new(*array)
    end

    def self.zero
      new(0, 0, 0)
    end

    def initialize(x, y, z)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def +(other) = self.class.new(x + other.x, y + other.y, z + other.z)
    def -(other) = self.class.new(x - other.x, y - other.y, z - other.z)
    def *(scalar) = self.class.new(x * scalar, y * scalar, z * scalar)

    def length = Math.sqrt(x * x + y * y + z * z)

    # A zero vector has no direction, so there is nothing to normalise it to. Returning it
    # unchanged keeps a degenerate surface degenerate rather than turning it into NaN,
    # which would propagate silently into geometry the client then fails to draw.
    def normalised
      magnitude = length
      magnitude.zero? ? self : self * (1.0 / magnitude)
    end

    def cross(other)
      self.class.new(
        y * other.z - z * other.y,
        z * other.x - x * other.z,
        x * other.y - y * other.x
      )
    end

    def dot(other) = x * other.x + y * other.y + z * other.z

    def to_a
      [ x, y, z ]
    end
    alias_method :to_spec, :to_a

    def ==(other)
      other.is_a?(Vector3) && to_a == other.to_a
    end
    alias_method :eql?, :==

    def hash
      to_a.hash
    end

    def inspect
      "#<Game::Vector3 (#{x}, #{y}, #{z})>"
    end
  end
end
