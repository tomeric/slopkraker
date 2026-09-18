module Game
  module Import
    # One Pand in, one category out, from cheap geometry: footprint area, tallest part,
    # rectangularity of the outline, slenderness of the most slender part, floor count,
    # and the OSM label where it names a landmark. Thresholds were swept against 1,875
    # OSM-labelled Pand in Geleen-Noord: houses 95%, sheds 99%, apartments 65%.
    module Classifier
      LANDMARKS = { "church" => :church, "chapel" => :church }.freeze

      def self.category(features)
        f = features.transform_keys(&:to_s)
        return LANDMARKS[f["osm"]] if LANDMARKS.key?(f["osm"])

        area = f["area"].to_f
        h = f["h_max"].to_f
        rect = f["union_rect"].to_f
        slender = f["slenderness"].to_f
        levels = f["levels"].to_i

        # A tower on an irregular footprint. Checked first: a church is mostly nave and
        # would otherwise read as a hall.
        return :church if slender > 2.0 && area > 300 && rect < 0.75
        # Nothing this low is lived in, and nothing this small is a house.
        return :shed if h < 4.0 && area < 60
        return :shed if area < 30
        # Big, low and boxy: a supermarket, a workshop, a school wing.
        return :hall if area > 400 && h < 9.0 && rect > 0.6
        # Three full storeys and bigger than a house, or many floors: flats.
        return :apartments if (area > 120 && h > 9.5) || levels >= 4
        return :hall if area > 400 && rect > 0.6
        return :church if area > 500 && rect < 0.6 && h > 10
        :house
      end
    end
  end
end
