require "test_helper"

# Geometry travels over HTTP and is immutable; damage travels over the socket. This is
# the first piece of geometry to make the trip.
class TerrainTilesControllerTest < ActionDispatch::IntegrationTest
  def tile
    @tile ||= terrain_tiles(:hills_west_north)
  end

  test "serves the row's bytes, raw, cacheable for a year and immutable" do
    get world_tile_path("hills", tile.digest, tile.tx, tile.tz)

    assert_response :success
    assert_equal "application/octet-stream", response.media_type
    assert_equal tile.heights, response.body.b
    assert_equal 41 * 41 * 2, response.body.bytesize
    assert_includes response.headers["Cache-Control"], "public"
    assert_includes response.headers["Cache-Control"], "immutable"
    assert_includes response.headers["Cache-Control"], "max-age=31556952"
  end

  # The digest is the tile's own bytes, so the URL changes if and only if the tile does.
  # A URL that has been cached as immutable answers for a year; the only safe thing for a
  # stale one to say is nothing.
  test "a stale digest is not found rather than served new bytes under an old name" do
    get world_tile_path("hills", "000000000000", tile.tx, tile.tz)

    assert_response :not_found
  end

  test "a tile that does not exist is not found" do
    get world_tile_path("hills", tile.digest, 7, 7)

    assert_response :not_found
  end

  test "a world that does not exist is not found" do
    get world_tile_path("nowhere", tile.digest, tile.tx, tile.tz)

    assert_response :not_found
  end

  test "the digest is twelve hex characters of the bytes" do
    assert_match(/\A[0-9a-f]{12}\z/, tile.digest)
    assert_equal Digest::SHA256.hexdigest(tile.heights)[0, 12], tile.digest
  end

  test "a manifest entry points at the served tile" do
    entry = tile.manifest_entry

    assert_equal %i[tx tz base_cm min_cm max_cm url].sort, entry.keys.sort
    assert_equal [ -1, -1 ], [ entry[:tx], entry[:tz] ]
    get entry[:url]
    assert_response :success
    assert_equal tile.heights, response.body.b
  end
end
