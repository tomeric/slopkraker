module Game
  # Exhaustive definition of a driveable vehicle. Every number the client's physics
  # step reads lives here -- the JS side holds no tuning constants of its own, so
  # retuning feel never means editing JavaScript.
  #
  # Tuning blocks are plain mutable hashes on purpose: the in-browser tuning panel
  # round-trips them, and `World#version` digests them so a client running stale
  # numbers can be detected rather than silently desyncing.
  class Vehicle
    attr_reader :key, :name, :action_label, :chassis, :engine, :steering, :slide, :slam, :turbo,
                :turbo_bar, :flip_recovery, :air_control, :breakthrough, :wheels, :parts,
                :camera, :audio

    def initialize(key:, name:, action_label:, chassis:, engine:, steering:, slide:, turbo:,
                   turbo_bar:, flip_recovery:, air_control:, breakthrough:, wheels:, parts:,
                   camera:, audio:, slam: nil)
      @key = key.to_sym
      @name = name
      @action_label = action_label
      @chassis = chassis
      @engine = engine
      @steering = steering
      @slide = slide
      @slam = slam
      @turbo = turbo
      @turbo_bar = turbo_bar
      @flip_recovery = flip_recovery
      @air_control = air_control
      @breakthrough = breakthrough
      @wheels = wheels
      @parts = parts
      @camera = camera
      @audio = audio
    end

    def build_turbo_bar
      TurboBar.new(**turbo_bar)
    end

    def part(kind)
      parts.find { |p| p.kind == kind.to_s }
    end

    def to_spec
      {
        key: key.to_s,
        name: name,
        action_label: action_label,
        chassis: chassis,
        engine: engine,
        steering: steering,
        slide: slide,
        slam: slam,
        turbo: turbo,
        turbo_bar: turbo_bar,
        flip_recovery: flip_recovery,
        air_control: air_control,
        breakthrough: breakthrough,
        wheels: wheels.map(&:to_spec),
        parts: parts.map(&:to_spec),
        camera: camera,
        audio: audio
      }
    end
  end
end
