module Game
  # The blast a rocket leaves behind. It is an object with a life of its own rather than
  # an instant of damage: the shell expands from a point out to `radius`, and whatever it
  # reaches takes a share of the damage scaled by how far out it had to travel.
  #
  # A target at distance d is reached when the shell is at d/radius and takes
  # force_at(d) of the damage -- which is the same falloff an instantaneous blast query
  # gives, only now it happens over time and can be watched.
  class Explosion
    attr_reader :radius, :expand_time, :linger, :prop_push, :prop_lift,
                :vehicle_share, :vehicle_lift, :colour

    def initialize(radius:, expand_time:, linger:, prop_push:, prop_lift:,
                   vehicle_share:, vehicle_lift:, colour: "#ffb03a")
      @radius = radius.to_f
      @expand_time = expand_time.to_f
      @linger = linger.to_f
      @prop_push = prop_push.to_f
      @prop_lift = prop_lift.to_f
      @vehicle_share = vehicle_share.to_f
      @vehicle_lift = vehicle_lift.to_f
      @colour = colour
    end

    # Eased out: a blast leaps outward and settles rather than creeping at a constant
    # rate. Purely cosmetic -- damage is a function of distance, so the curve decides
    # only WHEN something is caught, never how hard.
    def radius_at(elapsed)
      return radius if expand_time.zero?

      t = (elapsed.to_f / expand_time).clamp(0.0, 1.0)
      radius * (1 - (1 - t)**2)
    end

    # Share of the blast's damage something at this distance takes: everything at the
    # centre, nothing at the rim.
    def force_at(distance)
      return 0.0 if radius.zero?

      (1 - distance.to_f / radius).clamp(0.0, 1.0)
    end

    # A car caught in a blast is shoved by a share of what the same blast does to loose
    # scenery rather than by a figure of its own. Being launched clean across the arena by
    # a stray rocket stops being funny quickly, and tying the two together means tuning the
    # blast cannot accidentally make the car the thing that flies furthest.
    def vehicle_push
      prop_push * vehicle_share
    end

    # How long the thing exists for, expansion plus the moment it hangs in the air
    # afterwards.
    def duration
      expand_time + linger
    end

    def to_spec
      {
        radius: radius,
        expand_time: expand_time,
        linger: linger,
        prop_push: prop_push,
        prop_lift: prop_lift,
        vehicle_share: vehicle_share,
        vehicle_push: vehicle_push,
        vehicle_lift: vehicle_lift,
        colour: colour
      }
    end
  end
end
