module Game
  module Vehicles
    # Light, low, stiff and fast. Drifts readily, which is exactly how you line
    # up the rear bull bar. Rockets leave the launcher in a shallow arc.
    class Buggy
      WHEEL_BASE = 1.25
      FRONT_TRACK = 0.85
      REAR_TRACK = 0.88
      AXLE_HEIGHT = -0.12

      def self.build
        Vehicle.new(
          key: :buggy,
          name: "Buggy",
          action_label: "Fire rocket",
          chassis: {
            size: [ 1.8, 0.7, 3.2 ],
            mass: 900.0,
            centre_of_mass: [ 0.0, -0.25, 0.0 ],
            linear_damping: 0.04,
            angular_damping: 0.28,
            colour: "#f2c014",
            ride_height: 0.55,
            ccd: true,
            inertia_scale: [ 1.0, 0.7, 1.0 ]
          },
          engine: {
            force: 7200.0,
            top_speed: 38.0,
            reverse_force: 3800.0,
            reverse_top_speed: 12.0,
            brake_force: 9_500.0,
            engine_braking: 700.0
          },
          steering: {
            max_angle: 0.62,
            rate: 4.5,
            return_rate: 6.5,
            speed_falloff: 0.7,
            # Trail braking: weight moves forward under the brakes, so the nose bites and the
            # turn tightens. Without this, braking mid-corner only slows you down.
            brake_turn_assist: 0.40,
            brake_yaw_assist: 5_200.0,
            minimum_angle_ratio: 0.28
          },
          slide: {
            hop_impulse: 2_400.0,
            hop_cooldown: 0.35,
            engage_steer: 0.15,
            min_speed: 7.0,
            exit_speed: 3.0,
            rear_friction_scale: 0.10,
            front_friction_scale: 0.26,
            # Arc: how fast the velocity vector itself rotates. The pedals set the base
            # rate -- throttle and turbo widen it, brake tightens it -- and the stick then
            # trims that by +/- steer_arc_bounds. Leaning into the corner tightens, leaning
            # out widens, but only within those bounds: holding the stick cannot wind the
            # arc down indefinitely, which is what makes a tight corner a braking problem..
            min_turn_rate: 0.48,
            max_turn_rate: 1.30,
            steer_arc_bounds: 0.95,
            # Floor and ceiling on the trimmed result, as fractions of the pedal range. The
            # floor is what stops a held stick opening the arc out to a near-straight line,
            # which reads as the drift having quietly stopped working rather than as running
            # it wide; the ceiling stops it winding down to a spin. The floor is the binding
            # constraint on widening at every pedal setting, so it is the knob to reach for
            # when the stick wants more room to run the car wide.
            arc_floor_scale: 0.32,
            arc_ceiling_scale: 2.10,
            # How far the nose is cocked ahead of the direction of travel. This is the
            # part you can see: without it the car slides but never looks sideways.
            min_angle: 0.34,
            max_angle: 0.85,
            yaw_snap: 12.0,
            # Entry is ramped and the correction rate capped: slamming the nose to the
            # target angle on the first frame scrubs a third of the entry speed off.
            max_yaw_rate: 3.8,
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
            brake_decel: 7.5,
            coast_decel: 0.9,
            # Exiting a drift should flick the car straight and fire it out of the corner,
            # not hand it back to scrubbed tyres mid-turn. On release the chassis rotates
            # back against the drift (5 degrees) and is kicked along that new heading,
            # both eased in over exit_time rather than applied as a snap.
            exit_angle: 0.087,
            exit_time: 0.22,
            exit_kick_speed: 7.0,
            boost: {
              charge_time: 0.9,
              duration: 1.10,
              force_multiplier: 2.05,
              top_speed_multiplier: 1.35
            }
          },
          turbo: {
            force_multiplier: 2.0,
            top_speed_multiplier: 1.4,
            drain_rate: 25.0,
            fov_kick: 12.0
          },
          turbo_bar: {
            capacity: 100.0,
            recharge_rate: 20.0,
            recharge_delay: 0.35
          },
          flip_recovery: {
            torque: 13_000.0,
            max_speed: 3.0,
            up_dot_threshold: 0.15,
            settle_time: 0.5
          },
          air_control: {
            roll_torque: 5_000.0,
            pitch_torque: 2_800.0,
            max_angular_speed: 4.5,
            damping: 0.9
          },
          # See MonsterTruck#build for what these two mean. Both harsher here, and that is
          # the difference between the cars rather than a penalty on this one: the buggy
          # goes through glass and a partition without noticing and is very nearly stopped
          # by brick, where the truck shrugs the brick off. It has a rocket for the brick.
          breakthrough: {
            cost: 0.45,
            max_loss: 0.8
          },
          wheels: wheels,
          parts: [
            Parts::RocketLauncher.new(
              offset: Vector3.new(0.0, 0.55, -0.2),
              size: Vector3.new(0.3, 0.3, 1.1),
              cooldown: 0.1,
              ammo_cost: 10.0,
              launch_angle: 12.0,
              # Enough of a shove to feel the shot -- about 1.3 m/s off a 900kg car -- and
              # to slow you a touch if you fire while running flat out.
              recoil: 1200.0,
              rocket: rocket
            ),
            Parts::BullBar.new(
              offset: Vector3.new(0.0, 0.02, -1.75),
              # Wider than the bodywork on purpose: the solid section spans the 1.8 chassis
              # and the spikes are what stick out past it, one to each side.
              size: Vector3.new(2.5, 0.35, 0.25),
              spikes: { length: 0.35, radius: 0.12 },
              damage_multiplier: 3.0,
              minimum_slip_angle: 0.35,
              retain: 0.10,
              # Committing to a slide swings the bar out: hardest to the sides and backwards,
              # where the car is actually travelling, and far less forward. Lining the bar up
              # is the skill; catching the prop once you have should not come down to
              # centimetres.
              slide_extension: {
                sides: 0.85,
                back: 0.75,
                front: 0.25,
                # Snapping a solid box out to full size inside a prop it already overlaps
                # fires the thing across the arena, so the growth is eased in.
                ease_time: 0.12
              }
            )
          ],
          camera: camera,
          audio: audio
        )
      end



      def self.rocket
        Rocket.new(
          # Off the rail slowly, then it winds up under its own thrust: a rocket with room
          # to run lands far harder than one fired point blank.
          launch_speed: 18.0,
          mass: 12.0,
          radius: 0.16,
          # A shot into open air destroys itself rather than flying forever.
          lifetime: 5.0,
          minimum_damage: 90.0,
          max_damage: 380.0,
          damage_per_speed: 5.2,
          colour: "#ff5a1f",
          flight: flight,
          explosion: explosion
        )
      end

      # Two arcs, not one flat dart. The rocket lobs out of the launcher giving up speed to
      # drag and arcing under most of a gravity, then lights the motor near the apex and
      # runs -- at which point it accelerates hard and the arc flattens right out.
      #
      # Ignition tracks the apex rather than a stopwatch, bounded at both ends. Fired down
      # a slope the rocket is already falling on the first frame, which without min_time
      # would light the motor instantly and collapse the two arcs into one; fired from a
      # fast-moving buggy the apex may never arrive at all, hence max_time.
      #
      # It lights JUST BEFORE the apex, not at it: thrust only rescales the heading the
      # rocket already has, so igniting once it has levelled off leaves it flying flat a
      # metre above the ground with gravity tipping that heading straight into the dirt.
      # Firing while it is still climbing at ignite_climb gives the second arc somewhere
      # to go.
      #
      # ignite_climb also sets how long the first arc lasts, and at a 12 degree launch
      # there is not much climb to spend: too eager and the coast is over in a couple of
      # frames and there is only one arc to look at. Drag is what makes that coast read as
      # a coast rather than as a pause.
      def self.flight
        {
          coast: { drag: 14.0, gravity_scale: 0.75, ignite_climb: 0.9, min_time: 0.15, max_time: 0.9 },
          thrust: { acceleration: 58.0, max_speed: 64.0, gravity_scale: 0.30 }
        }
      end

      # The blast the rocket leaves behind: a shell that expands from a point out to its
      # radius, dealing less the further it has had to travel to reach you. prop_push is
      # impulse per point of damage and the lift numbers are the upward bias that makes a
      # blast throw debris into the air rather than skid it along the ground.
      #
      # vehicle_share is what a car takes of that: enough to rocket-jump off your own
      # shot, not enough to be flung across the arena by a stray one.
      def self.explosion
        Explosion.new(
          # Radius is the lever that makes a blast feel bigger, not damage. Everything
          # inside the shell is already comfortably past dying, so raising the number
          # changes nothing you can see -- widening the shell is what turns a hole into a
          # crater.
          radius: 2.5,
          expand_time: 0.22,
          linger: 0.20,
          prop_push: 1.15,
          prop_lift: 0.75,
          vehicle_share: 0.6,
          vehicle_lift: 0.8,
          colour: "#ffb03a"
        )
      end

      def self.wheels
        front_suspension = {
          rest_length: 0.32,
          stiffness: 38.0,
          compression: 2.2,
          relaxation: 3.2,
          max_travel: 0.22,
          max_force: 40_000.0
        }
        rear_suspension = front_suspension.merge(stiffness: 34.0, max_travel: 0.24)

        [
          [ "front_left",  -FRONT_TRACK,  WHEEL_BASE, front_suspension, true,  false, 1.35 ],
          [ "front_right",  FRONT_TRACK,  WHEEL_BASE, front_suspension, true,  false, 1.35 ],
          [ "rear_left",   -REAR_TRACK,  -WHEEL_BASE, rear_suspension,  false, true,  1.20 ],
          [ "rear_right",   REAR_TRACK,  -WHEEL_BASE, rear_suspension,  false, true,  1.20 ]
        ].map do |name, x, z, suspension, steered, slides, side_grip|
          Wheel.new(
            name: name,
            position: Vector3.new(x, AXLE_HEIGHT, z),
            radius: 0.42,
            width: 0.30,
            suspension: suspension.dup,
            friction_slip: 2.6,
            side_friction_stiffness: side_grip,
            driven: true,
            steered: steered,
            slides: slides
          )
        end
      end

      def self.camera
        {
          offset: [ 0.0, 2.9, -8.0 ],
          look_at_offset: [ 0.0, 0.9, 3.2 ],
          follow_stiffness: 6.5,
          look_stiffness: 10.0,
          drift_look: 0.50,
          drift_look_stiffness: 2.6,
          orbit_return_delay: 1.1,
          orbit_return_stiffness: 2.2,
          max_orbit_yaw: 2.6,
          max_orbit_pitch: 0.85,
          orbit_sensitivity: 0.0045,
          stick_sensitivity: 2.4,
          base_fov: 72.0,
          speed_fov_gain: 0.38,
          max_fov: 100.0,
          ground_clearance: 1.0
        }
      end

      def self.audio
        {
          # Pitched down and pulled well back. The engine is the one voice that never stops,
          # so it is the one that grates: it sets the floor everything else has to clear.
          engine: { idle_hz: 44.0, max_hz: 240.0, voices: 3, detune: 5.0, gain: 0.11, lowpass_hz: 1100.0 },
          turbo: { gain: 0.2, sweep_hz: [ 320.0, 2800.0 ] },
          rocket: { gain: 0.85, thump_hz: 80.0 },
          # The launch thump falls and the thrusters catching rises, so the two moments of
          # a single shot do not sound like the same event twice.
          ignition: { gain: 0.7, sweep_hz: [ 240.0, 1700.0 ] },
          # Held for as long as the motor burns, rather than a single crack at ignition.
          thrust: { gain: 0.34, band_hz: 820.0 },
          explosion: { gain: 0.95, boom_hz: 58.0 },
          impact: { gain: 0.55, band_hz: 280.0 },
          skid: { gain: 0.28, band_hz: 1900.0 },
          landing: { gain: 0.4, thump_hz: 90.0 }
        }
      end
    end
  end
end
