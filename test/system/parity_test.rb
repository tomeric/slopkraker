require "application_system_test_case"

# Five things run in both languages: the turbo bar, the damage formula with the parts
# that arm it, the blast curves, the surface grid, and the terrain sampler. Each JS file
# says it is "covered by a parity system test". This is that test. Both sides are handed
# the same cases from here, in one round trip per pair, and must give the same answers.
class ParityTest < ApplicationSystemTestCase
  setup do
    visit_world("hills", match: "parity")
    wait_for(message: "engine never booted") { page.evaluate_script("!!(window.__arena && window.__arena.ready)") }
    @spec = Game::Spec.for(worlds(:hills))
  end

  def parity(entry, *args)
    page.evaluate_script("window.__arenaParity.#{entry}(...arguments)", *args)
  end

  test "the turbo bar charges and drains identically" do
    spec = @spec.vehicle(:monster_truck).to_spec[:turbo_bar]
    ops = [
      [ "update", 0.5 ], [ "draw", 30.0 ], [ "update", 0.1 ], [ "update", 0.2 ], [ "update", 0.3 ],
      [ "draw", 25.0 ], [ "update", 1.0 ], [ "draw", 1000.0 ], [ "update", 0.05 ], [ "update", 4.0 ],
      [ "draw", 100.0 ], [ "update", 0.35 ], [ "update", 0.001 ], [ "update", 7.0 ]
    ]
    bar = Game::TurboBar.new(**spec)
    expected = ops.map do |op, value|
      if op == "draw"
        bar.draw(value)
        bar.level
      else
        bar.update(value)
      end
    end

    actual = parity("turboBar", spec, ops)

    expected.zip(actual).each_with_index do |(e, a), i|
      assert_in_delta e, a, 1e-9, "after step #{i} (#{ops[i].inspect})"
    end
  end

  test "damage resolves identically for every part, material, kind and state" do
    resolver = @spec.damage_resolver
    states = {
      "still" => {},
      "drifting_hard" => { drifting: true, slip_angle: 0.9 },
      "drifting_soft" => { drifting: true, slip_angle: 0.05 },
      "grace" => { drift_grace: 0.1 },
      "slamming_fast" => { slamming: true, fall_speed: -14.0 },
      "slamming_slow" => { slamming: true, fall_speed: -1.0 }
    }
    cases = []
    %i[monster_truck buggy].each do |key|
      ([ nil ] + @spec.vehicle(key).parts).each do |part|
        ([ nil ] + Game::Materials.names).each do |material|
          %w[impact blade bull_bar slam].each do |kind|
            states.each do |label, state|
              cases << { vehicle: key, part: part&.name, material: material&.to_s, kind: kind, state: state, speed: 12.0, label: label }
            end
          end
        end
      end
    end
    cases << { vehicle: :buggy, part: nil, material: "brick", kind: "impact", state: {}, speed: 3.0, label: "below threshold" }

    expected = cases.map do |c|
      part = c[:part] && @spec.vehicle(c[:vehicle]).parts.find { |p| p.name == c[:part] }
      material = c[:material] && Game::Materials.fetch(c[:material].to_sym)
      resolver.resolve(part: part, speed: c[:speed], state: c[:state], material: material, kind: c[:kind].to_sym)
    end

    actual = parity("damage", @spec.rules[:damage], cases)

    assert_equal expected.length, actual.length
    expected.zip(actual, cases).each do |e, a, c|
      assert_in_delta e, a, 1e-9, "#{c[:vehicle]} #{c[:part] || 'chassis'} on #{c[:material] || 'a prop'} by #{c[:kind]} while #{c[:label]}"
    end
  end

  test "a blast expands and falls off identically" do
    launcher = @spec.vehicle(:buggy).parts.find { |part| part.kind.to_s == "rocket_launcher" }
    explosion = launcher.rocket.explosion
    times = (0..12).map { |i| i * 0.05 }
    distances = (0..10).map { |i| i * explosion.radius / 8 }

    result = parity("explosion", explosion.to_spec, times, distances)

    times.zip(result["radius"]) { |t, r| assert_in_delta explosion.radius_at(t), r, 1e-9, "radius at #{t}" }
    distances.zip(result["force"]) { |d, f| assert_in_delta explosion.force_at(d), f, 1e-9, "force at #{d}" }
  end

  # Every cell, in index order, with its material. The arithmetic is trivial on both sides
  # and that is exactly why a divergence would be silent: nothing else checks it.
  test "a building expands to the same pieces in both languages" do
    house = worlds(:hills).world_objects.find_by!(name: "house")
    expected = house.surface_set.surfaces.flat_map do |surface|
      surface.rows.times.flat_map do |row|
        surface.cols.times.map { |col| [ surface.piece_index(row, col), surface.material_at(row, col).name.to_s ] }
      end
    end

    actual = parity("surface", house.id)

    assert_equal expected.length, actual.length, "the two sides expanded a different number of cells"
    first = expected.zip(actual).index { |e, a| e != a }
    return if first.nil?

    flunk "first divergence at position #{first}: ruby #{expected[first].inspect}, js #{actual[first].inspect}"
  end

  # The fourth pair, and the one whose divergence floats props. Sample points, cell
  # interiors, both seams from both sides.
  test "the ground samples identically" do
    sampler = worlds(:hills).sampler
    points = []
    (-195..195).step(13).each { |x| (-195..195).step(17).each { |z| points << [ x + 0.37, z + 0.61 ] } }
    [ 0.0, 1e-6, -1e-6 ].each do |d|
      (-190..190).step(20).each { |s| points << [ d, s ] << [ s, d ] }
    end
    (0..40).each { |i| points << [ -200 + i * 5, -200 + i * 5 ] }

    actual = parity("terrain", points)

    points.zip(actual).each do |(x, z), h|
      assert_in_delta sampler.height_at(x, z), h, 1e-4, "at (#{x}, #{z})"
    end
  end
end
