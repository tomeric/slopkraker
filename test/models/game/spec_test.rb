require "test_helper"

class Game::SpecTest < ActiveSupport::TestCase
  def spec
    @spec ||= Game::Spec.for(worlds(:targets)).to_spec
  end

  test "exposes the top level contract the client compiles against" do
    assert_equal %i[version arena vehicles materials palettes rules input].sort, spec.keys.sort
  end

  # The client reads this blob and nothing else. A Vector3 or a Symbol surviving into
  # it means the client silently receives "#<Game::Vector3...>" instead of numbers.
  test "serialises to JSON without leaking ruby objects" do
    round_tripped = JSON.parse(spec.to_json)
    assert_equal JSON.parse(JSON.generate(spec)), round_tripped
    assert_no_ruby_objects(round_tripped)
  end

  test "the material table ships with the spec" do
    # Every surface references a material by name, and the first one can arrive before any
    # other fetch resolves -- so the table has to be inline rather than fetched.
    assert_equal Game::Materials.names.map(&:to_s).sort, spec[:materials].keys.map(&:to_s).sort
    assert_operator spec[:materials][:glass][:health_per_m2], :<,
                    spec[:materials][:concrete][:health_per_m2]
  end

  # The scene is assembled from World rows now, so what is asserted is that a world
  # arrives intact -- not that it contains any particular furniture, which is the fixture's
  # business rather than the spec's.
  test "the scene carries gravity, ground and somewhere to spawn" do
    scene = spec[:arena]

    assert_equal [ 0.0, -9.81, 0.0 ], scene[:gravity]
    assert_includes scene[:bodies].map { |body| body[:kind] }, "ground"
    assert_not_empty scene[:spawns]
  end

  test "a world's props arrive as things that can be broken" do
    props = spec[:arena][:props]

    assert_equal %w[crate crate crate pillar], props.map { |prop| prop[:kind] }.sort
    props.each do |prop|
      assert_operator prop[:health], :>, 0, "#{prop[:name]} needs health to lose"
      assert_operator prop[:mass], :>, 0, "#{prop[:name]} needs mass to be shoved"
    end
  end

  # A spawn facing a wall is a spawn nobody can drive out of, so the heading is as much
  # part of it as the position.
  test "every spawn carries a position and a heading" do
    spec[:arena][:spawns].each do |spawn|
      assert_equal 3, spawn[:position].length
      assert_kind_of Float, spawn[:yaw]
    end
  end

  # The hard edges of the world. Nothing enforces them yet, but the client is handed them
  # from the first version of this payload so that adding the walls is not a wire change.
  test "the scene carries the world's bounds" do
    assert_equal [ -200, -200, 200, 200 ], spec[:arena][:bounds]
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
                      air_control breakthrough wheels parts camera audio key name
                      action_label].sort,
                   vehicle.keys.sort
      vehicle[:wheels].each do |wheel|
        assert_operator wheel[:radius], :>, 0
        assert_includes wheel.keys, :suspension
      end
    end
  end

  # What a wall costs to go through. The numbers themselves are feel and will move; which
  # car pays less is the design, and is what the truck being the one that ploughs through
  # things actually consists of.
  test "the truck goes through a wall more cheaply than the buggy" do
    truck = spec[:vehicles][:monster_truck][:breakthrough]
    buggy = spec[:vehicles][:buggy][:breakthrough]

    [ truck, buggy ].each do |car|
      assert_operator car[:cost], :>, 0, "a free breakthrough is a car that never slows down"
      # At 1.0 a wall may take everything, which is the stop this exists to prevent.
      assert_operator car[:max_loss], :<, 1.0, "a wall you got through has to leave you moving"
    end

    assert_operator truck[:cost], :<, buggy[:cost], "the truck is the one with the blade on it"
    assert_operator truck[:max_loss], :<, buggy[:max_loss]
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
    other = Game::Spec.for(worlds(:targets))
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

  test "the client is told how many hits a batch may carry" do
    assert_equal Game::Damage::MatchState::MAX_HITS_PER_BATCH,
                 Game::Spec.default_rules.dig(:damage, :max_hits_per_batch)
  end

  # Only the LOOK ships. The grid, the density and the height of a heap are constants in
  # Building::Rubble because they decide piece_count, and a client that disagreed about
  # those would be addressing different pieces than the server.
  test "the client is told how to draw a heap of rubble" do
    rubble = Game::Spec.default_rules.dig(:collapse, :rubble)

    assert rubble, "the rubble drawing rules never shipped"
    assert_operator rubble.fetch(:jitter), :>, 0
    assert_operator rubble.fetch(:tilt), :>, 0, "heaps that cannot lean read as paving"
    # A pile, not a carpet: the profile is a cosine bell raised to this, so any positive
    # exponent falls away from its middle -- and it must never reach zero at the rim or the
    # rim becomes invisible pieces with degenerate colliders.
    assert_operator rubble.fetch(:falloff), :>, 0.0
    assert_operator rubble.fetch(:edge), :>, 0.0
    assert_operator rubble.fetch(:edge), :<, 0.5

    # NO LUMP IN THE BODY OF THE PILE MAY BE TOO SMALL TO REACH ITS NEIGHBOUR. Heaps sit on
    # a grid of CELL metres and are CELL * SPREAD across before their size varies; if
    # varying can take one below the spacing it cannot touch the heaps beside it, and a
    # hole in the mound is the result -- which is exactly what pockets of air in a pile of
    # rubble are. The fringe is exempt: `rim` shrinks heaps BELOW the mean height, and at
    # the edge of a pile a gap is the edge, not a pocket.
    # Both shrinking factors at once: a heap at its smallest, on its narrower axis. Spread
    # alone was checked here once and the aspect quietly undid it -- the narrow axis came
    # out at 1.59m on a 2m grid while this assertion was passing.
    smallest = Game::Building::Rubble::CELL * Game::Building::Rubble::SPREAD *
               (1.0 - rubble.fetch(:spread)) / (1.0 + rubble.fetch(:aspect))

    assert_operator smallest, :>=, Game::Building::Rubble::CELL,
                    "the smallest heap is #{smallest.round(2)}m across on a " \
                    "#{Game::Building::Rubble::CELL}m grid, so it cannot reach its neighbours"

    # One number, in one place. Building::Rubble computes how DEEP a heap is against this
    # same share of its cell, so a second copy of it that drifted would leave the client
    # drawing heaps of a size the server never sized -- and the volume of wreckage a house
    # leaves would quietly stop being the volume the house was made of.
    assert_equal Game::Building::Rubble::SPREAD, rubble.fetch(:scale)
    assert_equal Game::Building::Rubble::SHAPES, rubble.fetch(:shapes)

    # The fringe shrinks with its height, but a rim heap keeps more than half its plan, so
    # the fringe breaks up into small mounds rather than vanishing into dots.
    assert_operator rubble.fetch(:rim), :>, 0.5
    assert_operator rubble.fetch(:rim), :<=, 1.0
    # A lopsided mound, within reason: the peak stays inside the middle half of the grid
    # and the lobes cannot fold the outline back on itself.
    assert_operator rubble.fetch(:offset), :>=, 0.0
    assert_operator rubble.fetch(:offset), :<, 0.25
    assert_operator rubble.fetch(:lobe), :>=, 0.0
    assert_operator rubble.fetch(:lobe), :<, 0.5

    # A third of every heap stands proud, whatever the seed picks. Below that a heap stops
    # being something you have to get around and becomes a stain on the ground.
    assert_operator rubble.fetch(:sink).max, :<=, 0.65
    assert_operator rubble.fetch(:sink).min, :>=, 0.0
  end

  # What a car or a blast does to the small stuff. It has no bodies, so the sweep is by
  # hand, and every number it uses is here.
  test "the client is told how debris is swept out of a car's way" do
    debris = Game::Spec.default_rules.fetch(:debris)

    assert_operator debris.fetch(:reach), :>=, 0
    %i[kick_speed kick_lift blast_speed blast_lift].each do |key|
      assert_operator debris.fetch(key), :>, 0, "#{key} of nothing is debris that does not move"
    end
    assert_operator debris.fetch(:kick_carry), :>=, 0
    assert_operator debris.fetch(:kicked_life), :>, 0
    assert_operator debris.fetch(:kicked_life), :<, 2.0, "kicked debris should be gone within the moment"
    # A blast must not sweep the shards it just threw, so fresh debris is left alone for at
    # least as long as a blast takes to expand.
    explosion = Game::Vehicles::Buggy.rocket.explosion.to_spec
    assert_operator debris.fetch(:grace), :>, explosion.fetch(:expand_time),
                    "a blast would sweep away its own shards"
  end

  # How a heap is populated, how it arrives and what it leaves. All tuning, all in Ruby.
  test "the client is told how many chunks a heap holds and what clearing one leaves" do
    rubble = Game::Spec.default_rules.dig(:collapse, :rubble)

    assert_kind_of Integer, rubble.fetch(:fragments)
    assert_operator rubble.fetch(:fragments), :>, 0, "a heap of nothing is a lump"
    assert_operator rubble.fetch(:rise), :>=, 0
    assert_kind_of Integer, rubble.fetch(:shards)

    remnants = rubble.fetch(:remnants)
    assert_operator remnants.fetch(:keep), :>=, 1, "clearing a heap has to leave something"
    assert_operator remnants.fetch(:keep) + rubble.fetch(:shards), :<=, rubble.fetch(:fragments),
                    "a heap cannot leave more chunks than it had"
    assert_operator remnants.fetch(:settle), :>=, 0
    assert_operator remnants.fetch(:linger), :>, 0, "the pieces should lie there a moment"
    assert_operator remnants.fetch(:fade), :>, 0, "the pieces should fade rather than blink out"
  end

  # A world without tiles is flat and says so with null, and every client that exists
  # today boots on exactly that.
  test "a world without tiles ships no terrain" do
    assert_nil Game::Spec.for(worlds(:flat)).to_spec[:arena][:terrain]
  end

  # The client fetches the tiles; the spec says where. The frame comes along whole because
  # it is what an imported world will need and it costs six keys.
  test "a world with tiles ships its frame and one url per tile" do
    terrain = Game::Spec.for(worlds(:hills)).to_spec[:arena][:terrain]

    assert_equal %i[srid origin tile_size height_step height_n chunk_size tiles].sort, terrain.keys.sort
    assert_equal 200, terrain[:tile_size]
    assert_equal 5, terrain[:height_step]
    assert_equal 41, terrain[:height_n]
    assert_equal 4, terrain[:tiles].length
    terrain[:tiles].each do |tile|
      assert_match(%r{\A/worlds/hills/[0-9a-f]{12}/tiles/-?\d+/-?\d+\z}, tile[:url])
      assert_operator tile[:min_cm], :<, tile[:max_cm]
    end
  end

  # Two tiles with different bytes must never share a URL -- that is the entire immutable
  # caching argument -- and the version has to move when the ground does.
  test "each tile has its own url and the version depends on them" do
    spec = Game::Spec.for(worlds(:hills)).to_spec
    urls = spec[:arena][:terrain][:tiles].map { |tile| tile[:url] }

    assert_equal urls.uniq, urls
    assert_not_equal Game::Spec.for(worlds(:flat)).to_spec[:version], spec[:version]
  end

  test "the terrain's look and feel are numbers in the rules" do
    terrain = Game::Spec.default_rules.fetch(:terrain)

    assert_operator terrain[:friction], :>, 0
    assert_equal %i[low high steep], terrain[:colours].keys
    terrain[:colours].each_value { |colour| assert_match(/\A#[0-9a-f]{6}\z/, colour) }
    from, to = terrain[:steep]
    assert_operator from, :<, to
  end

  # A road is a ribbon lying on the terrain, so the only numbers it needs are how far
  # above the ground it floats and what colour each kind of road is.
  test "roads ship how high they float and what colour each kind is" do
    roads = Game::Spec.default_rules.fetch(:roads)
    assert_operator roads[:lift], :>, 0
    %i[residential living_street tertiary secondary service cycleway].each { |kind| assert roads[:colours][kind], kind }
  end

  # On a downhill slope the camera behind the car goes under the ground and looks up
  # through a single-sided world. How far above the ground it is kept is a feel number.
  test "every camera keeps clear of the ground" do
    spec[:vehicles].each_value do |vehicle|
      assert_operator vehicle[:camera][:ground_clearance], :>, 0, "#{vehicle[:key]} camera"
    end
  end

  test "the palette table ships with the spec" do
    assert_equal Game::Palettes.names.map(&:to_s).sort, spec[:palettes].keys.map(&:to_s).sort
  end

  # Both skies whole, so the client can build either from the same numbers and the night
  # the game was lit for stays one URL parameter away.
  test "the client is told what the sky looks like, by day and by night" do
    sky = Game::Spec.default_rules.fetch(:sky)

    %i[day night].each do |time|
      entry = sky.fetch(time)
      %i[zenith horizon ground sun].each { |key| assert_match(/\A#[0-9a-f]{6}\z/i, entry.fetch(key), "#{time} #{key}") }
      assert_equal 3, entry.fetch(:hemisphere).length, "#{time} hemisphere is sky colour, ground colour, intensity"
      assert_operator entry.fetch(:sun_intensity), :>, 0
      assert_equal 3, entry.fetch(:sun_direction).length
      assert_operator entry.fetch(:sun_direction)[1], :>, 0, "#{time}'s sun is below the horizon"
      near, far = entry.fetch(:fog)
      assert_operator near, :<, far
    end
    assert_equal "#0e1116", sky.dig(:night, :horizon), "night is the sky the game was lit for until now"
  end

  test "the client is told how to draw a lawn and how much a wall may vary" do
    assert_match(/\A#[0-9a-f]{6}\z/i, Game::Spec.default_rules.dig(:gardens, :grass))
    assert_operator Game::Spec.default_rules.dig(:gardens, :lift), :<, Game::Spec.default_rules.dig(:roads, :lift),
                    "a lawn meeting a road must sit beneath it"
    jitter = Game::Spec.default_rules.dig(:looks, :jitter)
    assert_operator jitter, :>, 0
    assert_operator jitter, :<, 0.2, "a wall should not vary into a patchwork"
  end
end
