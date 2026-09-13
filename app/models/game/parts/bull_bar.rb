module Game
  module Parts
    # Rear-mounted bar. Only bites when the driver has committed to a drift,
    # which is the whole point: it rewards a deliberate manoeuvre, not a reverse bump.
    #
    # The gate is slip ANGLE, not lateral speed: a slide scrubs speed, so a genuine
    # drift can be slower sideways than a fast committed corner while being
    # far more sideways.
    class BullBar < Part
      attr_reader :minimum_slip_angle, :retain

      def initialize(offset:, size:, damage_multiplier:, minimum_slip_angle:, retain:, name: "bull_bar")
        super(name: name, offset: offset, size: size, damage_multiplier: damage_multiplier)
        @minimum_slip_angle = minimum_slip_angle.to_f
        @retain = retain.to_f
      end

      # `retain` keeps the bonus alive for a moment after the drift ends, so a hit that
      # lands just as you straighten up still counts. Getting that window right is a feel
      # question, hence the knob.
      def armed?(state = {})
        return true if state[:drift_grace].to_f.positive?
        return false unless state[:drifting]

        state[:slip_angle].to_f.abs >= minimum_slip_angle
      end

      def to_spec
        super.merge(minimum_slip_angle: minimum_slip_angle, retain: retain)
      end
    end
  end
end
