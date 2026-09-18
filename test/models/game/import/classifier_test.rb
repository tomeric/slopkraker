require "test_helper"

class Game::Import::ClassifierTest < ActiveSupport::TestCase
  AGREES = { shed: %w[shed garage garages roof service static_caravan], house: %w[house], apartments: %w[apartments],
             hall: %w[industrial retail commercial school office farm hospital parking construction], church: %w[church chapel] }.freeze

  def sample = JSON.parse(Rails.root.join("test/fixtures/files/geleen/classifier_sample.json").read)

  test "houses and sheds are recognised nine times in ten against OSM" do
    %i[house shed].each do |category|
      rows = sample.select { |r| Game::Import::Classifier.category(r) == category }
      agree = rows.count { |r| AGREES[category].include?(r["osm"]) }
      assert_operator agree.to_f / rows.length, :>=, 0.9, "#{category}: #{agree} of #{rows.length}"
    end
  end

  test "a tower on an irregular footprint is a church, and a box of flats is not" do
    church = { "area" => 1212, "h_max" => 23.4, "union_rect" => 0.63, "slenderness" => 3.41, "levels" => nil, "osm" => nil }
    flats = { "area" => 937, "h_max" => 13.1, "union_rect" => 1.0, "slenderness" => 0.43, "levels" => nil, "osm" => nil }
    assert_equal :church, Game::Import::Classifier.category(church)
    assert_equal :apartments, Game::Import::Classifier.category(flats)
  end

  test "an OSM landmark label overrides geometry" do
    box = { "area" => 607, "h_max" => 21.1, "union_rect" => 0.92, "slenderness" => 22.7, "levels" => nil, "osm" => "church" }
    assert_equal :church, Game::Import::Classifier.category(box)
  end
end
