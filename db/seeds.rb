# The worlds are defined once, in test/fixtures, and loaded from there into whichever
# database is asking. Tests get them automatically; development and CI get them here.
#
# Defining them twice would mean a test passing against one world while the browser shows
# another, which is exactly the class of bug this project already guards against with the
# spec version digest.
require "active_record/fixtures"

FIXTURES = %w[worlds world_objects].freeze

ActiveRecord::FixtureSet.create_fixtures(Rails.root.join("test/fixtures"), FIXTURES)

puts "Seeded #{World.count} worlds and #{WorldObject.count} objects."
