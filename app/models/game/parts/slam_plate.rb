module Game
  module Parts
    # The underside of the monster truck. Only bites when the truck is actively slamming
    # down on its jets and is genuinely falling -- landing gently on top of something is
    # not a slam.
    class SlamPlate < Part
      attr_reader :minimum_speed

      def initialize(offset:, size:, damage_multiplier:, minimum_speed:, name: "slam_plate")
        super(name: name, offset: offset, size: size, damage_multiplier: damage_multiplier)
        @minimum_speed = minimum_speed.to_f
      end

      def armed?(state = {})
        return false unless state[:slamming]

        state[:fall_speed].to_f.abs >= minimum_speed
      end

      def to_spec
        super.merge(minimum_speed: minimum_speed)
      end
    end
  end
end
