module Game
  # A building's colours are one key. Every recipe carries a palette name; the client
  # multiplies the palette's colour for a material's role into each instance where damage
  # darkening already lives, so one instanced pool still serves every building whatever
  # its palette, and no building costs a draw call of its own.
  #
  # The albedo textures are painted in value space -- light, nearly neutral -- so this
  # multiplication IS the colouring. brown_brick is tuned to reproduce today's colours, so
  # the four hand-made worlds, which name no palette, look like themselves.
  module Palettes
    # brick colours walls and gable ends; roof_tile the roof planes; door the door leaves.
    # Glass, steel, plaster, concrete and timber decks keep their material's own colour.
    ROLES = %i[brick roof_tile door].freeze
    DEFAULT = :brown_brick

    TABLE = {
      brown_brick: { brick: "#a8674a", roof_tile: "#8c3b2e", door: "#5a2a1e" },
      red_brick:   { brick: "#9a4b32", roof_tile: "#7a3a2c", door: "#2f4b3e" },
      sand_brick:  { brick: "#c8a878", roof_tile: "#8d4a35", door: "#33383d" },
      dark_brick:  { brick: "#4e3a33", roof_tile: "#2e3034", door: "#7a2c22" },
      church:      { brick: "#6e4a3a", roof_tile: "#3a3f47", door: "#3a2a22" }
    }.freeze

    def self.fetch(key) = TABLE.fetch(key.to_sym)
    def self.key?(key) = TABLE.key?(key.to_s.to_sym)
    def self.names = TABLE.keys

    def self.to_spec
      TABLE.transform_values { |palette| palette.transform_keys(&:to_s) }
    end
  end
end
