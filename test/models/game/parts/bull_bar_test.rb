require "test_helper"

class Game::Parts::BullBarTest < ActiveSupport::TestCase
  def bar
    Game::Parts::BullBar.new(
      offset: Game::Vector3.new(0, 0.4, -1.8),
      size: Game::Vector3.new(1.8, 0.3, 0.2),
      damage_multiplier: 3.0,
      minimum_slip_angle: 0.35,
      retain: 0.1
    )
  end

  # A bar that grows mid-slide. Round numbers so the arithmetic is readable: a 2.0 x 0.4 x
  # 0.2 box, so each half-extent is 1.0, 0.2 and 0.1.
  def extending_bar
    Game::Parts::BullBar.new(
      offset: Game::Vector3.new(0, 0.0, -2.0),
      size: Game::Vector3.new(2.0, 0.4, 0.2),
      damage_multiplier: 3.0,
      minimum_slip_angle: 0.35,
      retain: 0.1,
      slide_extension: { sides: 0.5, back: 0.5, front: 0.15, ease_time: 0.12 }
    )
  end

  # A spiked bar, 2.0 wide with 0.3 of spike at each end.
  def spiked_bar
    Game::Parts::BullBar.new(
      offset: Game::Vector3.new(0, 0.0, -2.0),
      size: Game::Vector3.new(2.0, 0.4, 0.2),
      damage_multiplier: 3.0,
      minimum_slip_angle: 0.35,
      retain: 0.1,
      spikes: { length: 0.3, radius: 0.12 }
    )
  end

  test "is armed only while drifting past the angle threshold" do
    assert bar.armed?(drifting: true, slip_angle: 0.6)
  end

  test "is not armed while drifting without slip" do
    assert_not bar.armed?(drifting: true, slip_angle: 0.1)
  end

  test "is not armed while sideways but not drifting" do
    assert_not bar.armed?(drifting: false, slip_angle: 1.1)
  end

  test "treats slip angle as a magnitude so either direction counts" do
    assert bar.armed?(drifting: true, slip_angle: -0.6)
  end

  test "is not armed given no state at all" do
    assert_not bar.armed?
  end

  # The grace window is what lets a hit land just as you straighten up out of the drift.
  test "stays armed while the drift grace is still running" do
    assert bar.armed?(drifting: false, slip_angle: 0.0, drift_grace: 0.05)
  end

  test "disarms once the grace has run out" do
    assert_not bar.armed?(drifting: false, slip_angle: 0.0, drift_grace: 0.0)
  end

  test "exposes the retain window so it can be tuned" do
    assert_equal 0.1, bar.retain
    assert_equal 0.1, bar.to_spec[:retain]
  end

  # --- the box grows mid-slide -------------------------------------------------
  #
  # Ruby works out the extended box so the client only has to ease between two shapes it
  # was handed, rather than re-deriving the geometry -- and so the arithmetic is covered
  # here rather than in a browser.

  test "extends to both sides by the fraction given" do
    assert_in_delta 3.0, extending_bar.extended_size.x, 1e-6
  end

  test "leaves its height alone when it extends" do
    assert_in_delta 0.4, extending_bar.extended_size.y, 1e-6
  end

  # The half-depth grows 0.1 -> 0.15 backwards but only 0.1 -> 0.115 forwards, so the box
  # ends up 0.265 deep rather than symmetrically 0.3.
  test "extends further back than forward" do
    assert_in_delta 0.265, extending_bar.extended_size.z, 1e-6
  end

  # Colliders are symmetric about their offset, so asymmetric growth has to move the box
  # as well as resize it: the back face drops 0.05 back, the front creeps 0.015 forward,
  # which puts the new centre 0.0175 behind the old one.
  test "shifts the extended box back so the extra depth lands behind the bar" do
    assert_in_delta(-2.0175, extending_bar.extended_offset.z, 1e-6)
  end

  test "extends squarely about the bar rather than off to one side" do
    assert_in_delta 0.0, extending_bar.extended_offset.x, 1e-6
    assert_in_delta 0.0, extending_bar.extended_offset.y, 1e-6
  end

  test "ships the extended box in the spec" do
    extension = extending_bar.to_spec[:slide_extension]

    assert_in_delta 3.0, extension[:size][0], 1e-6
    assert_in_delta(-2.0175, extension[:offset][2], 1e-6)
  end

  # Snapping a solid box out to full size inside a prop it already overlaps fires the
  # thing across the arena, so the client eases the change in over this window.
  test "ships the ease time so the growth can be ramped rather than snapped" do
    assert_in_delta 0.12, extending_bar.to_spec[:slide_extension][:ease_time], 1e-6
  end

  test "a bar given no extension keeps its resting box" do
    assert_nil bar.to_spec[:slide_extension]
  end

  # --- spikes on the ends ------------------------------------------------------
  #
  # The spikes live inside the bar's own width rather than beyond it, so the collider
  # covers what you can see: the solid section gives up exactly what the spikes take.

  test "the solid section gives up exactly what the spikes take" do
    assert_in_delta 1.4, spiked_bar.bar_width, 1e-6
  end

  test "a bar with no spikes is solid right across" do
    assert_in_delta bar.size.x, bar.bar_width, 1e-6
  end

  test "ships the spikes and the solid section they leave in the spec" do
    spikes = spiked_bar.to_spec[:spikes]

    assert_in_delta 0.3, spikes[:length], 1e-6
    assert_in_delta 0.12, spikes[:radius], 1e-6
    assert_in_delta 1.4, spikes[:bar_width], 1e-6
  end

  test "a bar given no spikes ships none" do
    assert_nil bar.to_spec[:spikes]
  end
end
