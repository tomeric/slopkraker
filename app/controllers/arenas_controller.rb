class ArenasController < ApplicationController
  # Until the city exists, flat ground is the only thing to stand on.
  DEFAULT_WORLD = "flat".freeze

  def show
    @world_record = World.find_by(slug: world_slug) || World.first
    return head :not_found if @world_record.nil?

    @world = Game::Spec.for(@world_record)
    @player_id = (session[:player_id] ||= SecureRandom.uuid)
    @match = params[:match].presence || ArenaChannel::DEFAULT_MATCH
  end

  private
    def world_slug
      params[:world].presence || DEFAULT_WORLD
    end
end
