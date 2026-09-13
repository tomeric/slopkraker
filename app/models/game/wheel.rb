module Game
  # One raycast wheel. `position` is the suspension anchor in chassis space; the
  # client hands these straight to Rapier's addWheel.
  class Wheel
    attr_reader :name, :position, :radius, :width, :suspension,
                :friction_slip, :side_friction_stiffness

    def initialize(name:, position:, radius:, width:, suspension:,
                   friction_slip:, side_friction_stiffness:,
                   driven: true, steered: false, slides: false)
      @name = name.to_s
      @position = position
      @radius = radius.to_f
      @width = width.to_f
      @suspension = suspension
      @friction_slip = friction_slip.to_f
      @side_friction_stiffness = side_friction_stiffness.to_f
      @driven = driven
      @steered = steered
      @slides = slides
    end

    def driven? = @driven
    def steered? = @steered
    # True for the wheels that give up grip in a drift -- the rears.
    def slides? = @slides

    def to_spec
      {
        name: name,
        position: position.to_a,
        radius: radius,
        width: width,
        suspension: suspension,
        friction_slip: friction_slip,
        side_friction_stiffness: side_friction_stiffness,
        driven: driven?,
        steered: steered?,
        slides: slides?
      }
    end
  end
end
