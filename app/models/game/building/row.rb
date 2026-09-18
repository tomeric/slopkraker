module Game
  module Building
    # A row of attached dwellings and the boxes beside them, in the row's own frame: x
    # along the row, z across it, the street at z = 0, every coordinate positive, and `yaw`
    # turning local into world about the object's position. A single house is a row of
    # one; a shed cluster or a church is a row of no dwellings and several boxes.
    class Row
      ROOFS = %w[gable flat].freeze
      BOX_ROOFS = %w[gable flat pyramid].freeze

      class Invalid < StandardError; end

      Dwelling = Struct.new(:x0, :x1, keyword_init: true) do
        def width = x1 - x0
      end

      # A one-or-more-storey ring with its own heights and roof: an annex, a shed, a garage,
      # a part of a church. `bay` says which dwelling it stands or falls with, or which bay
      # of its own it is; it is written by the importer and never guessed here.
      Box = Struct.new(:ring, :eaves, :ridge, :storeys, :roof, :door, :solid, :bay, :name, keyword_init: true) do
        def storey_height = eaves / storeys
        def bounds
          xs = ring.map(&:first)
          zs = ring.map(&:last)
          [ xs.min, zs.min, xs.max, zs.max ]
        end
      end

      attr_reader :yaw, :cell, :seed, :band, :storeys, :storey_height, :eaves, :ridge, :roof,
                  :dwellings, :boxes, :footprint, :category, :pands

      def self.from(attributes)
        a = attributes.to_h.transform_keys(&:to_s)
        new(
          yaw: a.fetch("yaw", 0.0).to_f, cell: a.fetch("cell", 1.0).to_f, seed: a.fetch("seed", 0).to_i,
          band: Array(a.fetch("band", [ 0.0, 0.0 ])).map(&:to_f),
          storeys: a.fetch("storeys", 1).to_i, storey_height: a.fetch("storey_height", 2.8).to_f,
          eaves: a.fetch("eaves", 2.8).to_f, ridge: a.fetch("ridge", a.fetch("eaves", 2.8)).to_f,
          roof: a.fetch("roof", "flat").to_s,
          dwellings: Array(a["dwellings"]).map { |d| d = d.transform_keys(&:to_s); Dwelling.new(x0: d.fetch("x0").to_f, x1: d.fetch("x1").to_f) },
          boxes: Array(a["boxes"]).map.with_index { |b, i| box_from(b, i) },
          footprint: Array(a.fetch("footprint")).map { |x, z| [ x.to_f, z.to_f ] },
          category: a.fetch("category", "building").to_s, pands: Array(a["pands"]).map(&:to_s)
        )
      end

      def self.box_from(hash, index)
        b = hash.transform_keys(&:to_s)
        eaves = b.fetch("eaves", b["height"]).to_f
        Box.new(
          ring: Array(b.fetch("ring")).map { |x, z| [ x.to_f, z.to_f ] }, eaves: eaves,
          ridge: b.fetch("ridge", eaves).to_f, storeys: b.fetch("storeys", 1).to_i, roof: b.fetch("roof", "flat").to_s,
          door: b.fetch("door", false), solid: b.fetch("solid", false), bay: b["bay"]&.to_i, name: b.fetch("name", "box-#{index}").to_s
        )
      end

      def initialize(yaw:, cell:, seed:, band:, storeys:, storey_height:, eaves:, ridge:, roof:, dwellings:, boxes:, footprint:, category:, pands:)
        @yaw, @cell, @seed, @band, @storeys, @storey_height = yaw, cell, seed, band, storeys, storey_height
        @eaves, @ridge, @roof, @dwellings, @boxes, @footprint, @category, @pands = eaves, ridge, roof, dwellings, boxes, footprint, category, pands
        validate!
      end

      def x0 = dwellings.first.x0
      def x1 = dwellings.last.x1
      def z0 = band[0]
      def z1 = band[1]
      def depth = z1 - z0
      def rise = [ ridge - eaves, 0.0 ].max
      # The row's rectangle in its own frame, or nil for a row of boxes only.
      def rect = dwellings.any? ? [ x0, z0, x1, z1 ] : nil
      def party_lines = dwellings.each_cons(2).map { |a, b| (a.x1 + b.x0) / 2.0 }

      private
        def validate!
          raise Invalid, "a footprint needs at least three points" if footprint.length < 3
          raise Invalid, "cell size must be positive" unless cell.positive?
          raise Invalid, "roof must be one of #{ROOFS.join(", ")}" unless ROOFS.include?(roof)
          raise Invalid, "the ridge cannot sit below the eaves" if ridge < eaves
          raise Invalid, "the band must run front to back" if dwellings.any? && z1 <= z0
          raise Invalid, "storeys must be positive" unless storeys.positive?
          dwellings.each { |d| raise Invalid, "a dwelling must have width" unless d.x1 > d.x0 }
          # Attached means attached, in both directions. Half a metre of slack absorbs the
          # disagreement between two imported party lines that are meant to be the same
          # line; past that a gap is not slack but a hole, and nothing downstream would
          # say so -- the front wall would be built with a length of nothing in it, the
          # party wall would float clear of both its neighbours, and the roof would come
          # apart over open air. The importer is the next caller, so it is caught here.
          dwellings.each_cons(2) do |a, b|
            raise Invalid, "dwellings must run left to right" if b.x0 < a.x1 - 0.5
            raise Invalid, "dwellings in a row must be attached" if b.x0 > a.x1 + 0.5
          end
          boxes.each do |box|
            raise Invalid, "a box needs a ring" if box.ring.length < 3
            raise Invalid, "a box roof must be one of #{BOX_ROOFS.join(", ")}" unless BOX_ROOFS.include?(box.roof)
            raise Invalid, "a box needs a bay" if box.bay.nil?
            raise Invalid, "a box must have storeys" unless box.storeys.positive?
          end
        end
    end
  end
end
