class EpicsController < ApplicationController
  before_action :load_epic

  def show
    @graph = EpicDependencyGraphRenderer.new(@epic).render
    @jobs = @epic.jobs.includes(:repository, :dependencies, :dependent_links).order(:id)
  end

  def update_state
    target_state = params[:target_state].to_s

    if ActiveModel::Type::Boolean.new.cast(params[:override])
      @epic.override_state!(target_state)
      respond_to_state_update
    elsif @epic.ready? && target_state == "in_progress"
      @epic.start!
      respond_to_state_update
    else
      respond_to do |format|
        format.html { redirect_back fallback_location: dashboard_epics_path, alert: "That Epic transition is not available from the board." }
        format.json { render json: { error: "transition_not_allowed" }, status: :unprocessable_entity }
      end
    end
  rescue ArgumentError
    respond_to do |format|
      format.html { redirect_back fallback_location: dashboard_epics_path, alert: "Unknown Epic state." }
      format.json { render json: { error: "unknown_state" }, status: :unprocessable_entity }
    end
  end

  private

  def load_epic
    @epic = Current.user.epics.includes(:repository).find(params[:id])
  end

  def respond_to_state_update
    respond_to do |format|
      format.html { redirect_back fallback_location: dashboard_epics_path, notice: "Epic updated." }
      format.json { render json: { state: @epic.reload.state } }
    end
  end
end
