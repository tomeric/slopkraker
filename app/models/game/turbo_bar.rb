module Game
  # Shared resource behind turbo boost, jump jets and rockets. Draining it is what
  # makes "boost or shoot" a real choice.
  #
  # Recharge is suspended for `recharge_delay` after any draw. That delay is what
  # keeps the specified "10 rockets on a full bar" honest: rockets fire at a 100ms
  # floor, so a delay longer than the cooldown means sustained fire never earns
  # free shots mid-burst.
  class TurboBar
    # Per-frame accumulation drifts by ~1e-14 over a full recharge. Without a snap the
    # bar would sit a hair under capacity forever and never read as full.
    EPSILON = 1e-9

    attr_reader :capacity, :recharge_rate, :recharge_delay, :level

    def initialize(capacity:, recharge_rate:, recharge_delay:)
      @capacity = capacity.to_f
      @recharge_rate = recharge_rate.to_f
      @recharge_delay = recharge_delay.to_f
      @level = @capacity
      @since_draw = Float::INFINITY
    end

    def full?
      level >= capacity - EPSILON
    end

    def empty?
      level <= EPSILON
    end

    def fraction
      return 0.0 if capacity.zero?
      level / capacity
    end

    # Returns false and leaves the level untouched when the bar cannot cover the cost.
    def draw(amount)
      amount = amount.to_f
      return false if amount > level

      @level -= amount
      @since_draw = 0.0
      true
    end

    def update(dt)
      dt = dt.to_f
      @since_draw += dt

      idle = @since_draw - recharge_delay
      return level if idle <= 0

      # Only the portion of this step that fell after the delay expired earns charge.
      charged = level + recharge_rate * [ idle, dt ].min
      @level = charged >= capacity - EPSILON ? capacity : charged
    end
  end
end
