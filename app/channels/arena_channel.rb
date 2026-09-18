# Relays vehicle snapshots between players in a match, and is the authority on what that
# match has destroyed.
#
# Two halves with deliberately opposite rules. Vehicles are relayed and never simulated:
# each client authoritatively simulates its own car, and stamping identity is the whole of
# the server's job, because simulating would cap feel at the network tick rate.
#
# Destruction is the other way round. A client predicts its own breaks -- it must, or
# driving through a wall would bounce you off while a round trip completed -- but the
# server decides, because a collapse follows from the sum of what every player has done to
# a building and no client can see that sum.
class ArenaChannel < ApplicationCable::Channel
  DEFAULT_MATCH = "lobby".freeze
  # Which process holds a match. Regenerated per boot, so a restart reads as a new
  # claimant rather than silently inheriting the old one's matches.
  AUTHORITY = "#{Socket.gethostname}-#{Process.pid}-#{SecureRandom.hex(4)}".freeze

  def subscribed
    @match = sanitised_match(params[:match])
    @world = World.find_by(slug: params[:world].to_s)
    @record = Match.start(key: @match, world: @world) if @world
    @authoritative = @record ? @record.claim(AUTHORITY) : false
    stream_from stream_name

    broadcast(type: "join")
  end

  def unsubscribed
    broadcast(type: "leave")
    Game::Damage::Registry.release(@record) if @record
  end

  # What a client says it hit. Applied here, never recomputed -- the server does not
  # simulate. What goes back out is authoritative and monotone, so a break this client
  # already predicted is simply confirmed and never has to be walked back.
  def damage(data)
    return unless @record
    return transmit({ type: "error", reason: "not_authoritative" }) unless @authoritative

    result = Game::Damage::Registry.checkout(@record) do |state|
      state.apply_batch(data["hits"])
    end
    transmit({ type: "error", reason: "batch_truncated", kept: Game::Damage::MatchState::MAX_HITS_PER_BATCH }) if result["truncated"]
    return if result["broken"].empty? && result["collapses"].empty?

    # Deliberately NOT stamped with player_id. NetConnection drops its own echo, and the
    # client that caused a collapse is the one that most needs to hear about it.
    ActionCable.server.broadcast(stream_name, {
      "type" => "breaks", "authority" => AUTHORITY,
      "broken" => result["broken"], "collapses" => result["collapses"]
    })
  end

  # What is already broken of the objects a client has just loaded. Sent back to the asker
  # alone rather than broadcast -- nobody else asked, and this is the largest message the
  # protocol has.
  def request_state(data)
    return unless @record

    objects = Game::Damage::Registry.checkout(@record) do |state|
      state.state_for(data["ids"])
    end

    transmit({ type: "state", authority: AUTHORITY, objects: objects })
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
