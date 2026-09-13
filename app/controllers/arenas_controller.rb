class ArenasController < ApplicationController
  def show
    @world_record = requested_world
    # No world asked for, or one that does not exist: offer the choice rather than
    # guessing. Quietly loading somewhere else is how a typo in a link ends up looking
    # like a bug in the world it was not supposed to load.
    return render :select, status: status_for_selection if @world_record.nil?

    @world = Game::Spec.for(@world_record)
    @player_id = (session[:player_id] ||= SecureRandom.uuid)
    @match = params[:match].presence || ArenaChannel::DEFAULT_MATCH
  end

  private
    def requested_world
      return nil if requested_slug.blank?

      World.find_by(slug: requested_slug)
    end

    def requested_slug
      params[:world].presence
    end

    def status_for_selection
      @worlds = World.order(:name)
      @unknown = requested_slug
      @unknown ? :not_found : :ok
    end
end
