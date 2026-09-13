module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :player_id

    # Identity is established by the HTTP request that rendered the arena (see
    # ArenasController) and read back here from the signed session cookie, so a client
    # cannot choose its own id.
    def connect
      self.player_id = request.session[:player_id] || reject_unauthorized_connection
    end
  end
end
