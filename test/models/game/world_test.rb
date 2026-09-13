require "test_helper"

class Game::WorldTest < ActiveSupport::TestCase
  def spec
    @spec ||= Game::World.build.to_spec
  end

  test "exposes the top level contract the client compiles against" do
    assert_equal %i[version arena vehicles rules input].sort, spec.keys.sort
  end

  # The client reads this blob and nothing else. A Vector3 or a Symbol surviving into
  # it means the client silently receives "#<Game::Vector3...>" instead of numbers.
  test "serialises to JSON without leaking ruby objects" do
    round_tripped = JSON.parse(spec.to_json)
    assert_equal JSON.parse(JSON.generate(spec)), round_tripped
    assert_no_ruby_objects(round_tripped)
  end

  test "the arena is walled, has ramps and somewhere to spawn" do
    arena = spec[:arena]
    assert_equal [ 0.0, -9.81, 0.0 ], arena[:gravity]
    kinds = arena[:bodies].map { |b| b[:kind] }
    assert_includes kinds, "ground"
    assert_operator kinds.count("wall"), :>=, 4, "arena must be enclosed"
    assert_operator kinds.count("ramp"), :>=, 3, "need ramps to test physics against"
    assert_not_empty arena[:spawns]
  end

  test "the arena carries a circuit with corners and real elevation" do
    bodies = spec[:arena][:bodies]
    road = bodies.select { |b| b[:kind] == "road" }

    assert_operator road.length, :>, 40, "the circuit needs enough slabs to corner smoothly"
    # Deliberately unbarriered for now so you can run wide and drift back on.
    assert_equal 0, bodies.count { |b| b[:kind] == "barrier" }
    heights = road.map { |b| b[:position][1] }
    assert_operator heights.max - heights.min, :>, 8.0,
      "the circuit needs real elevation change to test landings"

    # The track has to fit inside the walls it is drawn in.
    half = spec[:arena][:size] / 2
    road.each do |slab|
      assert_operator slab[:position][0].abs, :<, half, "#{slab[:name]} outside the arena"
      assert_operator slab[:position][2].abs, :<, half, "#{slab[:name]} outside the arena"
    end
  end

  test "players spawn on the circuit" do
    road = spec[:arena][:bodies].select { |b| b[:kind] == "road" }

    spec[:arena][:spawns].each do |spawn|
      position = spawn[:position]
      nearest = road.map { |slab|
        Math.sqrt((slab[:position][0] - position[0])**2 + (slab[:position][2] - position[2])**2)
      }.min
      assert_operator nearest, :<, Game::Track::WIDTH, "spawn #{position.inspect} is off the track"
      assert spawn[:yaw].is_a?(Float), "spawn needs a heading or the car drives off the circuit"
    end
  end

  test "every static body carries a full transform and size" do
    spec[:arena][:bodies].each do |body|
      assert_equal 3, body[:position].length, "#{body[:name]} position"
      assert_equal 3, body[:size].length, "#{body[:name]} size"
      assert_equal 4, body[:rotation].length, "#{body[:name]} rotation must be a quaternion"
    end
  end

  test "ships both vehicles" do
    assert_equal %w[buggy monster_truck], spec[:vehicles].keys.map(&:to_s).sort
  end

  test "every vehicle has four wheels and a complete tuning block" do
    spec[:vehicles].each_value do |vehicle|
      assert_equal 4, vehicle[:wheels].length, "#{vehicle[:key]} wheels"
      assert_equal %i[chassis engine steering slide slam turbo turbo_bar flip_recovery
                      air_control wheels parts camera audio key name action_label].sort,
                   vehicle.keys.sort
      vehicle[:wheels].each do |wheel|
        assert_operator wheel[:radius], :>, 0
        assert_includes wheel.keys, :suspension
      end
    end
  end

  test "the monster truck carries a blade and jump jets" do
    parts = spec[:vehicles][:monster_truck][:parts].map { |p| p[:kind] }
    assert_includes parts, "bulldozer_blade"
    assert_includes parts, "jump_jets"
  end

  test "the buggy carries a rocket launcher and a bull bar" do
    parts = spec[:vehicles][:buggy][:parts].map { |p| p[:kind] }
    assert_includes parts, "rocket_launcher"
    assert_includes parts, "bull_bar"
  end

  test "a full bar buys a drift boost worth having" do
    spec[:vehicles].each_value do |vehicle|
      boost = vehicle[:slide][:boost]
      assert_operator boost[:charge_time], :>, 0.0, "#{vehicle[:key]} boost charge"
      assert_operator boost[:force_multiplier], :>, 1.0, "#{vehicle[:key]} boost must actually boost"
      assert_operator vehicle[:slide][:hop_impulse], :>, vehicle[:chassis][:mass] * 2,
        "#{vehicle[:key]} hop should clear the ground"
    end
  end

  test "drifting cuts rear grip far more than front" do
    spec[:vehicles].each_value do |vehicle|
      slide = vehicle[:slide]
      assert_operator slide[:rear_friction_scale], :<, slide[:front_friction_scale],
        "#{vehicle[:key]} needs the rear to let go first"
    end
  end

  test "every turbo bar recharges to full in five seconds" do
    spec[:vehicles].each_value do |vehicle|
      bar = vehicle[:turbo_bar]
      assert_in_delta 5.0, bar[:capacity] / bar[:recharge_rate], 1e-9, "#{vehicle[:key]} recharge"
    end
  end

  test "a full bar buys the buggy exactly ten rockets" do
    buggy = spec[:vehicles][:buggy]
    launcher = buggy[:parts].find { |p| p[:kind] == "rocket_launcher" }

    assert_in_delta 10.0, buggy[:turbo_bar][:capacity] / launcher[:ammo_cost], 1e-9
    assert_in_delta 0.1, launcher[:cooldown], 1e-9
    assert_operator buggy[:turbo_bar][:recharge_delay], :>, launcher[:cooldown]
  end

  test "the controls panel documents every binding it lists" do
    spec[:input][:display].each do |entry|
      assert_not_empty entry[:label], entry[:control]
      assert entry[:keys].any? || entry[:pad], "#{entry[:control]} has no binding to show"
    end
    controls = spec[:input][:display].map { |e| e[:control] }
    assert_includes controls, "slide"
    assert_includes controls, "action"
  end

  test "each vehicle names what its action key does" do
    assert_equal "Jump jets", spec[:vehicles][:monster_truck][:action_label]
    assert_equal "Fire rocket", spec[:vehicles][:buggy][:action_label]
  end

  test "input bindings cover keyboard and gamepad" do
    assert_equal %i[keyboard gamepad display].sort, spec[:input].keys.sort
    %i[throttle brake steer_left steer_right slide turbo action].each do |control|
      assert_includes spec[:input][:keyboard].keys, control
    end
  end

  test "the version changes when tuning changes" do
    other = Game::World.build
    other.vehicles.fetch(:buggy).engine[:force] += 1

    assert_not_equal spec[:version], other.to_spec[:version]
  end

  # --- the bull bar reaches out mid-slide --------------------------------------
  #
  # Measured off the faces of the shipped box rather than its raw numbers: what matters is
  # how much further the bar reaches in each direction, which is what the driver feels.

  test "the buggy's bull bar reaches out to both sides mid-slide" do
    bar = buggy_bull_bar

    assert_in_delta 1.85, bar[:slide_extension][:size][0] / bar[:size][0], 1e-9,
      "the bar should be well over half again as wide while sliding"
  end

  test "the buggy's bull bar reaches three quarters again as far back mid-slide" do
    bar = buggy_bull_bar
    reach = (back_face(bar[:offset], bar[:size]) -
             back_face(bar[:slide_extension][:offset], bar[:slide_extension][:size]))

    assert_in_delta 0.75, reach / (bar[:size][2] / 2), 1e-9
  end

  # Far less than it reaches back: the bar is there to catch what you swing it into, not to
  # turn the back of the buggy into a second front bumper.
  test "the buggy's bull bar reaches only modestly further forward mid-slide" do
    bar = buggy_bull_bar
    reach = (front_face(bar[:slide_extension][:offset], bar[:slide_extension][:size]) -
             front_face(bar[:offset], bar[:size]))

    assert_in_delta 0.25, reach / (bar[:size][2] / 2), 1e-9
  end

  # A taller bar would start catching things it is meant to pass under.
  test "the buggy's bull bar does not grow taller mid-slide" do
    bar = buggy_bull_bar

    assert_in_delta bar[:size][1], bar[:slide_extension][:size][1], 1e-9
  end

  test "the buggy's bull bar ramps its growth rather than snapping to it" do
    assert_operator buggy_bull_bar[:slide_extension][:ease_time], :>, 0.0
  end

  test "the buggy's bull bar sticks out past the bodywork" do
    assert_operator buggy_bull_bar[:size][0], :>, spec[:vehicles][:buggy][:chassis][:size][0],
      "the bar should be visible past the bodywork, not tucked inside it"
  end

  # The spikes are drawn within the bar's own width so the collider covers what you can
  # see. That only works while they leave a solid section between them.
  test "the buggy's bull bar spikes leave a solid section between them" do
    spikes = buggy_bull_bar[:spikes]

    assert_operator spikes[:bar_width], :>, 0.0
    assert_in_delta buggy_bull_bar[:size][0], spikes[:bar_width] + 2 * spikes[:length], 1e-9
  end

  test "the buggy has a voice for the rocket lighting up and for it going off" do
    audio = spec[:vehicles][:buggy][:audio]

    assert audio[:ignition], "the thrusters catching should be audible"
    assert audio[:explosion], "a blast should be audible"
  end

  # --- the stick trims the drift arc -------------------------------------------

  # The client clamps the trimmed arc between these; without them in the spec it reads
  # undefined, the turn rate goes NaN and the drift silently stops steering.
  test "every vehicle bounds how far the stick can trim the drift arc" do
    spec[:vehicles].each_value do |vehicle|
      slide = vehicle[:slide]
      assert_operator slide[:arc_floor_scale], :<, 1.0,
        "#{vehicle[:key]}: the stick should open the arc wider than the pedals alone reach"
      assert_operator slide[:arc_ceiling_scale], :>, 1.0,
        "#{vehicle[:key]}: the stick should tighten the arc beyond the pedals alone reach"
    end
  end

  # At a trim of exactly 1.0 the widening side collapses -- base * (1 - 1) is zero whatever
  # the pedals are doing, so every pedal setting bottoms out on the same floor and the
  # stick stops expressing anything on that side.
  test "no vehicle trims the drift arc so hard that widening collapses" do
    spec[:vehicles].each_value do |vehicle|
      assert_operator vehicle[:slide][:steer_arc_bounds], :<, 1.0, vehicle[:key].to_s
    end
  end

  # --- the rocket flies in two arcs --------------------------------------------

  test "the buggy's rocket ships both flight phases" do
    flight = buggy_rocket[:flight]

    assert flight[:coast], "no coast phase, so the rocket cannot lob"
    assert flight[:thrust], "no thrust phase, so the rocket cannot wind up"
  end

  # A heavy lob and then a flat run is what makes two arcs read as two arcs rather than
  # as one long curve.
  test "the buggy's rocket arcs harder coasting than it does under power" do
    flight = buggy_rocket[:flight]

    assert_operator flight[:coast][:gravity_scale], :>, flight[:thrust][:gravity_scale]
  end

  # Ignition tracks the apex, but bounded: fired down a slope the rocket is already
  # falling on the first frame, and fired from a fast buggy the apex may never arrive.
  test "the buggy's rocket always coasts for a moment before it can ignite" do
    coast = buggy_rocket[:flight][:coast]

    assert_operator coast[:min_time], :>, 0.0
    assert_operator coast[:max_time], :>, coast[:min_time]
  end

  # Igniting at the apex leaves it flying flat a metre off the ground, and the first thing
  # thrust does is tip that heading into the dirt.
  test "the buggy's rocket lights its thrusters before it stops climbing" do
    assert_operator buggy_rocket[:flight][:coast][:ignite_climb], :>, 0.0
  end

  test "the buggy's rocket ignites well within its own lifetime" do
    assert_operator buggy_rocket[:flight][:coast][:max_time], :<, buggy_rocket[:lifetime]
  end

  test "the buggy's rocket carries a blast that expands rather than landing all at once" do
    blast = buggy_rocket[:explosion]

    assert_operator blast[:radius], :>, 0.0
    assert_operator blast[:expand_time], :>, 0.0
  end

  private
    def buggy_rocket
      spec[:vehicles][:buggy][:parts].find { |p| p[:kind] == "rocket_launcher" }[:rocket]
    end

    def buggy_bull_bar
      spec[:vehicles][:buggy][:parts].find { |p| p[:kind] == "bull_bar" }
    end

    def back_face(offset, size)
      offset[2] - size[2] / 2
    end

    def front_face(offset, size)
      offset[2] + size[2] / 2
    end

    def assert_no_ruby_objects(node, path = "root")
      case node
      when Hash  then node.each { |k, v| assert_no_ruby_objects(v, "#{path}.#{k}") }
      when Array then node.each_with_index { |v, i| assert_no_ruby_objects(v, "#{path}[#{i}]") }
      when String, Numeric, TrueClass, FalseClass, NilClass then nil
      else flick(path, node)
      end
    end

    def flick(path, node)
      flunk "#{path} serialised as #{node.class}: #{node.inspect}"
    end
end
