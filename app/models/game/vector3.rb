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
