module Game
  # Bindings are data, not JavaScript constants -- the client normalises every source
  # into one input struct using these. Keyboard entries are KeyboardEvent.code values.
  class InputBindings
    # Xbox face/shoulder labels by standard Gamepad API index.
    PAD_LABELS = {
      0 => "A", 1 => "B", 2 => "X", 3 => "Y", 4 => "LB", 5 => "RB",
      6 => "LT", 7 => "RT", 8 => "View", 9 => "Menu", 10 => "L3", 11 => "R3"
    }.freeze

    KEY_LABELS = {
      "ArrowUp" => "Up", "ArrowDown" => "Down", "ArrowLeft" => "Left", "ArrowRight" => "Right",
      "ShiftLeft" => "Shift", "ShiftRight" => "Shift", "ControlLeft" => "Ctrl",
      "Space" => "Space", "Backquote" => "`"
    }.freeze

    # What the on-screen controls panel shows, in order. Lives here so the panel can never
    # drift from the bindings it documents.
    DISPLAY = [
      [ :throttle,        "Accelerate" ],
      [ :brake,           "Brake / reverse" ],
      [ :steer_left,      "Steer left" ],
      [ :steer_right,     "Steer right" ],
      [ :pitch_forward,   "Air: nose down" ],
      [ :pitch_back,      "Air: nose up" ],
      [ :slide,           "Slide (hop to drift)" ],
      [ :turbo,           "Turbo" ],
      [ :action,          "Action" ],
      [ :respawn,         "Respawn" ],
      [ :camera_recentre, "Recentre camera" ],
      [ :switch_vehicle,  "Switch vehicle" ],
      [ :toggle_controls, "Hide controls" ],
      [ :toggle_debug,    "Debug overlay" ],
      [ :toggle_mute,     "Mute sound" ]
    ].freeze

    # Steering is one analogue axis on a pad but two keys, so it needs spelling out.
    PAD_OVERRIDES = {
      steer_left: "LS left",
      steer_right: "LS right",
      pitch_forward: "LS up",
      pitch_back: "LS down",
      camera: "RS"
    }.freeze

    def self.build
      new(keyboard: keyboard, gamepad: gamepad)
    end

    def self.key_label(code)
      KEY_LABELS[code] || code.delete_prefix("Key")
    end

    def self.pad_label(control)
      return PAD_OVERRIDES[control] if PAD_OVERRIDES.key?(control)

      binding = gamepad[control]
      return nil unless binding.is_a?(Hash) && binding[:button]

      PAD_LABELS[binding[:button]]
    end

    def self.display
      DISPLAY.map do |control, label|
        {
          control: control.to_s,
          label: label,
          keys: Array(keyboard[control]).map { |code| key_label(code) },
          pad: pad_label(control)
        }
      end
    end

    def self.keyboard
      {
        throttle: %w[KeyW],
        brake: %w[KeyS],
        steer_left: %w[KeyA ArrowLeft],
        steer_right: %w[KeyD ArrowRight],
        pitch_forward: %w[ArrowUp],
        pitch_back: %w[ArrowDown],
        slide: %w[Space],
        turbo: %w[ShiftLeft ShiftRight],
        action: %w[KeyE ControlLeft],
        respawn: %w[KeyR],
        switch_vehicle: %w[KeyV],
        camera_recentre: %w[KeyC],
        toggle_controls: %w[KeyH],
        toggle_debug: %w[KeyG],
        toggle_mute: %w[KeyM],
        toggle_tuning: %w[Backquote]
      }
    end

    # Standard Gamepad API mapping (Xbox layout):
    #   0 A   1 B   2 X   3 Y   4 LB  5 RB  6 LT  7 RT
    #   8 View  9 Menu  10 L3  11 R3
    # Triggers are analogue buttons, so they carry a value rather than a pressed flag.
    #
    # Driver's layout: throttle on RT, turbo on RB under the same finger, brake on LB and
    # slide on LT so a drift can be set up with the left hand while both thumbs stay
    # on steering and camera. Action sits on A.
    def self.gamepad
      {
        throttle: { button: 7 },
        brake: { button: 4 },
        steer: { axis: 0 },
        # Left stick Y. Airborne pitch only -- it does nothing on the ground.
        pitch: { axis: 1 },
        camera_yaw: { axis: 2 },
        camera_pitch: { axis: 3 },
        slide: { button: 6 },
        turbo: { button: 5 },
        action: { button: 0 },
        respawn: { button: 3 },
        switch_vehicle: { button: 8 },
        camera_recentre: { button: 10 },
        toggle_controls: { button: 9 },
        toggle_debug: { button: 1 },
        toggle_mute: { button: 11 },
        deadzone: 0.15,
        trigger_deadzone: 0.05,
        steer_curve: 1.6
      }
    end

    attr_reader :keyboard, :gamepad

    def initialize(keyboard:, gamepad:)
      @keyboard = keyboard
      @gamepad = gamepad
    end

    def to_spec
      { keyboard: keyboard, gamepad: gamepad, display: self.class.display }
    end
  end
end
