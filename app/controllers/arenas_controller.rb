class ArenasController < ApplicationController
  def show
    @world = Game::World.build
    @player_id = (session[:player_id] ||= SecureRandom.uuid)
    @match = params[:match].presence || ArenaChannel::DEFAULT_MATCH
  end
end
