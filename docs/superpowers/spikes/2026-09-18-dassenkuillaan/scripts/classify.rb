# Throwaway classifier for the spike. One Pand in, one category out, from cheap geometry
# signals. Scored against OSM labels where both exist.
require "json"

module Classify
  # Category => which OSM labels count as agreeing with it. `yes` is unlabelled.
  AGREES = {
    shed: %w[shed garage garages roof service static_caravan],
    house: %w[house],
    apartments: %w[apartments],
    hall: %w[industrial retail commercial school office farm warehouse hospital parking construction],
    church: %w[church chapel],
    tower: %w[tower water_tower]
  }.freeze

  def self.category(p)
    area = p["area"].to_f
    h = p["h_max"].to_f
    rect = p["union_rect"].to_f
    slender = p["slenderness"].to_f
    levels = p["levels"].to_i

    # A spire or a tower: something small carrying real height. Checked first, because a
    # church is mostly nave and would otherwise read as a hall.
    return :church if slender > 2.0 && area > 300 && rect < 0.75
    return :tower if slender > 2.0 && area < 120 && h > 12
    # Nothing that low is lived in, and nothing that small is a house.
    return :shed if h < 4.0 && area < 60
    return :shed if area < 30
    # Big, low and boxy: a hall -- a supermarket, a workshop, a school wing.
    return :hall if area > 400 && h < 9.0 && rect > 0.6
    # Tall enough for three full storeys and bigger than a house, or many levels: flats.
    # Thresholds swept against the OSM labels: 120 m2 / 9.5 m is the best split here.
    return :apartments if (area > 120 && h > 9.5) || levels >= 4
    return :hall if area > 400 && rect > 0.6
    # An awkward large outline that is tall enough: church-shaped without a tower.
    return :church if area > 500 && rect < 0.6 && h > 10
    :house
  end

  def self.report(rows)
    cats = rows.group_by { |p| category(p) }
    puts "%-11s %6s %8s %8s %8s   %s" % %w[category pand avg_m2 avg_h max_h scored/agree/acc]
    cats.sort_by { |c, ps| -ps.size }.each do |cat, ps|
      labelled = ps.reject { |p| p["osm"].nil? || p["osm"] == "yes" }
      agree = labelled.count { |p| AGREES.fetch(cat, []).include?(p["osm"]) }
      acc = labelled.empty? ? "-" : "%3d%%" % (100.0 * agree / labelled.size)
      puts "%-11s %6d %8.0f %8.1f %8.1f   %4d/%4d/%s" % [
        cat, ps.size, ps.sum { |p| p["area"].to_f } / ps.size, ps.sum { |p| p["h_max"].to_f } / ps.size,
        ps.map { |p| p["h_max"].to_f }.max, labelled.size, agree, acc
      ]
    end
    # Where the disagreements are.
    puts "\nconfusion (rows: mine, cols: OSM), labelled only"
    labels = rows.map { |p| p["osm"] }.compact.uniq - [ "yes" ]
    labels = labels.sort_by { |l| -rows.count { |p| p["osm"] == l } }
    puts "%-11s " % "" + labels.map { |l| "%9s" % l[0, 9] }.join
    cats.sort_by { |c, ps| -ps.size }.each do |cat, ps|
      puts "%-11s " % cat + labels.map { |l| "%9d" % ps.count { |p| p["osm"] == l } }.join
    end
    cats
  end
end

if __FILE__ == $0
  rows = JSON.parse(File.read(ARGV[0]))
  puts "#{rows.size} Pand"
  puts "neighbours: #{rows.map { |p| p["neighbours"] }.tally.sort.to_h}"
  puts "OSM labels: #{rows.map { |p| p["osm"] || "NULL" }.tally.sort_by { |_, n| -n }.to_h}"
  puts
  cats = Classify.report(rows)
  # The window and the contrast window, for the report.
  [ [ "50 m window", 186330, 332234, 50 ], [ "contrast 120 m", 186100, 331420, 120 ] ].each do |name, x, y, r|
    inside = rows.select { |p| Math.hypot(p["cx"] - x, p["cy"] - y) <= r }
    puts "\n#{name}: #{inside.size} Pand by centroid -> #{inside.group_by { |p| Classify.category(p) }.transform_values(&:size).sort_by { |_, n| -n }.to_h}"
  end
end
