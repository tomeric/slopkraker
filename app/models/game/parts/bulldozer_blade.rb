module Game
  module Parts
    # Front-mounted plough. Always armed -- if you hit something with the blade, the
    # blade is what did it.
    class BulldozerBlade < Part
      def initialize(offset:, size:, damage_multiplier:, name: "bulldozer_blade")
        super(name: name, offset: offset, size: size, damage_multiplier: damage_multiplier)
      end
    end
  end
end
