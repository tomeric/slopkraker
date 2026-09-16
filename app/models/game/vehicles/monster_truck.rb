module Game
  module Vehicles
    # Heavy, tall, long-travel suspension, medium top speed. Ploughs with the blade and
    # can save a bad line with the jets. Air control is roll-biased: steering in the air
    # shifts weight left/right rather than yawing.
    class MonsterTruck
      WHEEL_BASE = 1.45
      TRACK = 0.95
      AXLE_HEIGHT = -0.20

      # Booster nozzles. Inboard of the tyres -- their inner face sits at
      # TRACK - width/2 = 0.725 -- and just below the slam plate, so they read as firing
      # through it. The roof nozzle is the same thruster pointed the other way.
      NOZZLE_TRACK = 0.52
      NOZZLE_REACH = 1.42
      NOZZLE_DROP = -0.56
      NOZZLE_RADIUS = 0.15

      def self.build
        Vehicle.new(
          key: :monster_truck,
          name: "Monster Truck",
          action_label: "Jump jets",
          chassis: {
            size: [ 2.2, 1.0, 4.0 ],
            mass: 1800.0,
            centre_of_mass: [ 0.0, -0.35, 0.0 ],
            linear_damping: 0.05,
            angular_damping: 0.35,
            colour: "#c1440e",
            ride_height: 0.95,
            ccd: true,
            inertia_scale: [ 1.0, 0.8, 1.0 ]
          },
          engine: {
            force: 9000.0,
            top_speed: 28.0,
            reverse_force: 5000.0,
            reverse_top_speed: 10.0,
            brake_force: 11_000.0,
            engine_braking: 900.0
          },
          steering: {
            max_angle: 0.55,
            rate: 3.2,
            return_rate: 5.0,
            speed_falloff: 0.55,
            # Trail braking: weight moves forward under the brakes, so the nose bites and the
            # turn tightens. Without this, braking mid-corner only slows you down.
            brake_turn_assist: 0.35,
            brake_yaw_assist: 9_500.0,
            minimum_angle_ratio: 0.35
          },
          slide: {
            hop_impulse: 4_300.0,
            hop_cooldown: 0.40,
            engage_steer: 0.15,
            min_speed: 6.0,
            exit_speed: 3.0,
            rear_friction_scale: 0.12,
            front_friction_scale: 0.28,
            # The drift is a servo on slip ANGLE, not a constant torque: constant torque
            # has no equilibrium, so the car keeps rotating until it spins out.
            #
            # Steering picks the drift direction and then holds a fixed lock -- leaning on
            # the stick does NOT keep tightening the arc. The arc is set with the pedals:
            # throttle and turbo widen it, brake tightens it. Taking a genuinely tight
            # corner means braking into the drift.
            # Arc: how fast the velocity vector itself rotates. The pedals set the base
            # rate -- throttle and turbo widen it, brake tightens it -- and the stick then
            # trims that by +/- steer_arc_bounds. Leaning into the corner tightens, leaning
            # out widens, but only within those bounds: holding the stick cannot wind the
            # arc down indefinitely, which is what makes a tight corner a braking problem..
            min_turn_rate: 0.40,
            max_turn_rate: 1.05,
            steer_arc_bounds: 0.75,
            # Floor and ceiling on the trimmed result, as fractions of the pedal range: the
            # floor stops a held stick opening the arc out to a near-straight line, the
            # ceiling stops it winding down to a spin.
            arc_floor_scale: 0.50,
            arc_ceiling_scale: 1.75,
            # How far the nose is cocked ahead of the direction of travel. This is the
            # part you can see: without it the car slides but never looks sideways.
            min_angle: 0.30,
            max_angle: 0.72,
            yaw_snap: 11.0,
            # Entry is ramped and the correction rate capped: slamming the nose to the
            # target angle on the first frame scrubs a third of the entry speed off.
            max_yaw_rate: 3.2,
            entry_time: 0.35,
            steer_lock: 0.22,
            throttle_widen: 0.55,
            turbo_widen: 0.45,
            brake_tighten: 1.0,
            # Braking mid-drift tightens the arc; at full force it would simply stop the car
            # before the arc could bend, so the pedal is scaled down while sliding.
            brake_scale: 0.30,
            # While drifting the longitudinal dynamics are owned by the drift, in m/s^2, so
            # momentum is carried through the corner instead of being scrubbed off by the
            # tyres. Braking here tightens the arc AND sheds speed at a controlled rate.
            # Drifting must not out-run driving straight, or it becomes a speed exploit
            # rather than a cornering tool.
            accel_scale: 0.55,
            speed_cap: 0.82,
            brake_decel: 6.5,
            coast_decel: 1.1,
            # Exiting a drift should flick the car straight and fire it out of the corner,
            # not hand it back to scrubbed tyres mid-turn. On release the chassis rotates
            # back against the drift (5 degrees) and is kicked along that new heading,
            # both eased in over exit_time rather than applied as a snap.
            exit_angle: 0.087,
            exit_time: 0.22,
            exit_kick_speed: 6.0,
            boost: {
              charge_time: 1.0,
              duration: 1.05,
              force_multiplier: 1.90,
              top_speed_multiplier: 1.30
            }
          },
          turbo: {
            force_multiplier: 1.8,
            top_speed_multiplier: 1.35,
            drain_rate: 25.0,
            fov_kick: 9.0
          },
          turbo_bar: {
            capacity: 100.0,
            recharge_rate: 20.0,
            recharge_delay: 0.35
          },
          flip_recovery: {
            torque: 26_000.0,
            max_speed: 3.0,
            up_dot_threshold: 0.15,
            settle_time: 0.6
          },
          air_control: {
            roll_torque: 11_000.0,
            pitch_torque: 5_000.0,
            max_angular_speed: 4.5,
            damping: 0.9
          },
          # Jets point down to lift; the slam is the same thruster pointed up, driving the
          # truck into the ground. Ramping means a longer hold lands harder.
          slam: {
            # Airborne for this long before the thruster will flip. Without it, holding
            # Slide through the drift hop slams you straight back into the ground and
            # hop-to-drift never gets off the floor.
            engage_delay: 0.22,
            initial_thrust: 27_000.0,
            ramp: 72_000.0,
            max_thrust: 130_000.0
          },
          # What going through a wall costs you. A wall that stops you dead reads as a wall
          # you bounced off, however much of it is lying on the floor afterwards.
          #
          # `cost` is a multiple of the speed the wall was worth, and its worth is not a
          # new number: damage is (speed - minimum_speed) * damage_per_speed, so the health
          # just destroyed inverts to the speed it took to destroy it. It is well under one
          # because a hit is generous on purpose -- the blade is 2.6m wide and reaches six
          # piece colliders at once, so one good impact on this house takes out eighteen
          # cells and seventy-five health. That is 37 m/s of worth against a truck that
          # tops out at 28, which is why paying the wall in full can only ever stop it.
          # What this multiplies is therefore how much of a HOLE you made, and it is what
          # keeps a pane of glass cheaper than a brick wall.
          #
          # `max_loss` is the part you can read off the screen: whatever the arithmetic
          # says, a wall you got through may not take more than this share of the speed you
          # arrived with. It is what makes "keeps some momentum" true rather than likely,
          # and it is the clause that bites when you arrive slowly -- exactly when the
          # proportional term would otherwise leave you stationary in your own hole.
          #
          # Neither applies to a wall that is still standing. Fail to break the concrete
          # and it stops you, as it should.
          breakthrough: {
            cost: 0.15,
            max_loss: 0.55
          },
          wheels: wheels,
          parts: [
            Parts::BulldozerBlade.new(
              offset: Vector3.new(0.0, -0.12, 2.25),
              size: Vector3.new(2.6, 0.9, 0.3),
              damage_multiplier: 5.0
            ),
            Parts::SlamPlate.new(
              offset: Vector3.new(0.0, -0.42, 0.0),
              size: Vector3.new(2.0, 0.22, 3.6),
              damage_multiplier: 4.0,
              minimum_speed: 4.5
            ),
            Parts::JumpJets.new(
              offset: Vector3.new(0.0, -0.1, -2.0),
              size: Vector3.new(0.5, 0.5, 0.7),
              thrust: 42_000.0,
              drain_rate: 40.0,
              flame: flame,
              nozzles: nozzles
            )
          ],
          camera: camera,
          audio: audio
        )
      end

      def self.wheels
        suspension = {
          rest_length: 0.55,
          stiffness: 28.0,
          compression: 1.7,
          relaxation: 2.6,
          max_travel: 0.45,
          max_force: 60_000.0
        }

        [
          [ "front_left",  -TRACK,  WHEEL_BASE, true,  false ],
          [ "front_right",  TRACK,  WHEEL_BASE, true,  false ],
          [ "rear_left",   -TRACK, -WHEEL_BASE, false, true ],
          [ "rear_right",   TRACK, -WHEEL_BASE, false, true ]
        ].map do |name, x, z, steered, slides|
          Wheel.new(
            name: name,
            position: Vector3.new(x, AXLE_HEIGHT, z),
            radius: 0.65,
            width: 0.45,
            suspension: suspension.dup,
            friction_slip: 2.2,
            side_friction_stiffness: 1.15,
            driven: true,
            steered: steered,
            slides: slides
          )
        end
      end

      # The boosters that make the burn legible. The bias signs encode the chassis axes --
      # +X is the driver's LEFT, and a nozzle underneath pushes its own corner UP -- so the
      # side that has to RISE is the side that burns. Parts::JumpJets carries the
      # derivation; MonsterTruckTest pins it.
      def self.nozzles
        corners = [
          [ "front_left",   1,  1 ],
          [ "front_right", -1,  1 ],
          [ "rear_left",    1, -1 ],
          [ "rear_right",  -1, -1 ]
        ].map do |name, side, nose|
          {
            name: name,
            group: "lift",
            offset: Vector3.new(side * NOZZLE_TRACK, NOZZLE_DROP, nose * NOZZLE_REACH),
            direction: Vector3.new(0.0, -1.0, 0.0),
            radius: NOZZLE_RADIUS,
            flame_length: 0.5,
            # Steering right lifts the left side, so +X burns as input.steer goes positive.
            roll_bias: side.to_f,
            # input.pitch is +1 nose-down, which raises the tail, so -Z burns.
            pitch_bias: -nose.to_f
          }
        end

        corners + [ {
          name: "slam",
          group: "slam",
          offset: Vector3.new(0.0, 0.62, -0.30),
          direction: Vector3.new(0.0, 1.0, 0.0),
          radius: 0.19,
          flame_length: 0.6,
          # A slam holds Slide, which is exactly what switches air control off, so there is
          # no attitude left for the roof nozzle to report.
          roll_bias: 0.0,
          pitch_bias: 0.0
        } ]
      end

      def self.flame
        {
          core_colour: "#ffd066",
          glow_colour: "#ff8a3d",
          # How fast a nozzle chases its target brightness, 1/s. Snapping makes the rig
          # strobe every time the stick crosses centre.
          response: 16.0,
          # 1.0 spends the full range on the stick: the dark side goes right out, which is
          # what makes the attitude readable at a glance.
          tilt_authority: 1.0,
          # Length and opacity jitter, as fractions of the resting flame.
          flicker: [ 0.78, 1.22 ],
          opacity: [ 0.72, 1.0 ],
          glow_scale: 1.7
        }
      end

      def self.camera
        {
          offset: [ 0.0, 4.0, -9.5 ],
          look_at_offset: [ 0.0, 1.2, 3.0 ],
          follow_stiffness: 5.5,
          look_stiffness: 9.0,
          drift_look: 0.42,
          drift_look_stiffness: 2.6,
          orbit_return_delay: 1.2,
          orbit_return_stiffness: 2.0,
          max_orbit_yaw: 2.6,
          max_orbit_pitch: 0.85,
          orbit_sensitivity: 0.0045,
          stick_sensitivity: 2.4,
          base_fov: 70.0,
          speed_fov_gain: 0.32,
          max_fov: 94.0,
          # How far the camera is kept above the terrain under it, in metres. On a downhill
          # slope the camera behind the car would otherwise sink under the ground.
          ground_clearance: 1.2
        }
      end

      def self.audio
        {
          # Pitched down and pulled well back: the engine never stops, so it sets the floor
          # everything else has to clear.
          engine: { idle_hz: 34.0, max_hz: 175.0, voices: 3, detune: 7.0, gain: 0.13, lowpass_hz: 800.0 },
          turbo: { gain: 0.2, sweep_hz: [ 260.0, 2400.0 ] },
          jets: { gain: 0.34, band_hz: 380.0, q: 0.8 },
          impact: { gain: 0.6, band_hz: 220.0 },
          skid: { gain: 0.22, band_hz: 1600.0 },
          landing: { gain: 0.5, thump_hz: 70.0 }
        }
      end
    end
  end
end
