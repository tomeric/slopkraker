ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Named rather than `fixtures :all`, and this is load-bearing.
    #
    # A table's fixtures may be ONE file or a DIRECTORY of them, and an imported world has
    # to be a directory: bin/rails geleen:import rewrites test/fixtures/worlds/geleen.yml
    # wholesale, and a generated file cannot share a file with hand-written ones. Rails
    # merges `worlds.yml` and `worlds/*.yml` into the one set -- but only when the set is
    # NAMED. `fixtures :all` globs files instead, so it reads worlds/geleen.yml as a set
    # called "worlds/geleen" and goes looking for a table named `worlds_geleen`, which
    # fails at the first test with an error that says nothing about fixtures.
    #
    # The same three names db/seeds.rb loads, in the same way, so the suite and the browser
    # cannot end up standing in different worlds.
    fixtures :worlds, :terrain_tiles, :world_objects

    # A binary file for a test to read back, written where parallel workers can all see it.
    #
    # Renamed into place rather than written into place, because the suite forks. binwrite
    # TRUNCATES first and fills after, so a worker holding the file open -- Dem opens its
    # grid once and seeks in it -- reads back an empty file for as long as that window is
    # open, and gets nil where it expected four bytes. Renaming is atomic: a reader gets one
    # whole file or the other, and a handle already open keeps reading the one it opened.
    def binary_fixture(name, bytes)
      path = Rails.root.join("tmp", name)
      scratch = Rails.root.join("tmp", "#{name}.#{Process.pid}")
      scratch.binwrite(bytes)
      scratch.rename(path.to_s)
      path
    end
  end
end
