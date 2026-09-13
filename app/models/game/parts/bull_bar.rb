module Game
  module Parts
    # Rear-mounted bar. Only bites when the driver has committed to a drift,
    # which is the whole point: it rewards a deliberate manoeuvre, not a reverse bump.
    #
    # The gate is slip ANGLE, not lateral speed: a slide scrubs speed, so a genuine
    # drift can be slower sideways than a fast committed corner while being
    # far more sideways.
    class BullBar < Part
      attr_reader :minimum_slip_angle, :retain, :slide_extension, :spikes

      def initialize(offset:, size:, damage_multiplier:, minimum_slip_angle:, retain:,
                     slide_extension: nil, spikes: nil, name: "bull_bar")
        super(name: name, offset: offset, size: size, damage_multiplier: damage_multiplier)
        @minimum_slip_angle = minimum_slip_angle.to_f
        @retain = retain.to_f
        @slide_extension = slide_extension&.symbolize_keys
        @spikes = spikes&.symbolize_keys
      end

      # `retain` keeps the bonus alive for a moment after the drift ends, so a hit that
      # lands just as you straighten up still counts. Getting that window right is a feel
      # question, hence the knob.
      def armed?(state = {})
        return true if state[:drift_grace].to_f.positive?
        return false unless state[:drifting]

        state[:slip_angle].to_f.abs >= minimum_slip_angle
      end

      def extends?
        slide_extension.present?
      end

      def spiked?
        spikes.present?
      end

      # The spikes sit inside the bar's own width rather than beyond it, so the collider
      # covers what you can see: the solid section gives up exactly what they take.
      def bar_width
        return size.x unless spiked?

        size.x - 2 * spikes[:length].to_f
      end

      # Sideways the bar grows symmetrically, so the width simply scales. Height is left
      # alone: a taller bar would start catching things it is meant to pass under.
      def extended_size
        return size unless extends?

        Vector3.new(size.x * (1 + fraction(:sides)), size.y, back_half + front_half)
      end

      # A collider is symmetric about its own offset, so growing further back than forward
      # means moving the box as well as resizing it -- by half the difference between the
      # two new half-depths, which is what keeps the front face where the arithmetic says.
      def extended_offset
        return offset unless extends?

        Vector3.new(offset.x, offset.y, offset.z - (back_half - front_half) / 2)
      end

      # The client eases between the resting box and this one rather than re-deriving the
      # geometry, so the numbers stay Ruby's and the arithmetic stays unit-tested.
      def to_spec
        super.merge(
          minimum_slip_angle: minimum_slip_angle,
          retain: retain,
          slide_extension: extension_spec,
          spikes: spikes_spec
        )
      end

      private
        def extension_spec
          return nil unless extends?

          {
            size: extended_size.to_a,
            offset: extended_offset.to_a,
            ease_time: slide_extension[:ease_time].to_f
          }
        end

        def spikes_spec
          return nil unless spiked?

          {
            length: spikes[:length].to_f,
            radius: spikes[:radius].to_f,
            bar_width: bar_width
          }
        end

        def fraction(key)
          slide_extension[key].to_f
        end

        def back_half
          (size.z / 2) * (1 + fraction(:back))
        end

        def front_half
          (size.z / 2) * (1 + fraction(:front))
        end
    end
  end
end
