# Relays vehicle snapshots between players in a match.
#
# Each client authoritatively simulates its own vehicle and broadcasts a transform
# snapshot; the server only stamps identity and fans out. It never simulates -- that
# would cap feel at the network tick rate.
class ArenaChannel < ApplicationCable::Channel
  DEFAULT_MATCH = "lobby".freeze

  def subscribed
    @match = sanitised_match(params[:match])
    stream_from stream_name

    broadcast(type: "join")
  end

  def unsubscribed
    broadcast(type: "leave")
  end

  # Snapshots arrive ~20Hz per client. Everything is relayed verbatim except player_id,
  # which is stamped here rather than trusted from the payload.
  def snapshot(data)
    broadcast(
      type: "snapshot",
      vehicle: data["vehicle"],
      t: data["t"],
      p: data["p"],
      q: data["q"],
      v: data["v"],
      w: data["w"],
      f: data["f"]
    )
  end

  private
    def broadcast(payload)
      ActionCable.server.broadcast(stream_name, payload.merge(player_id: player_id))
    end

    def stream_name
      "arena:#{@match}"
    end

    def sanitised_match(value)
      candidate = value.to_s.strip
      return DEFAULT_MATCH unless candidate.match?(/\A[a-zA-Z0-9_-]{1,32}\z/)

      candidate
    end
end
