# One tile of heightfield, as the raw bytes the row holds.
#
# No file cache and no tempfile-and-rename: a tile is a seeded row, not something built on
# demand, so send_data from the column is one query and there is nothing to make atomic.
# The response is immutable for a year because the digest in the URL is the digest of the
# bytes -- change the tile and the URL changes with it.
class TerrainTilesController < ApplicationController
  def show
    world = World.find_by!(slug: params[:slug])
    tile = world.terrain_tiles.find_by!(tx: params[:tx], tz: params[:tz])
    # A stale digest is a stale page. Serving the current bytes under the old name would
    # put them in a cache that keeps them for a year.
    raise ActiveRecord::RecordNotFound unless tile.digest == params[:digest]

    expires_in 1.year, public: true, immutable: true
    send_data tile.heights, type: "application/octet-stream", disposition: "inline"
  end
end
