class EpicsController < ApplicationController
  before_action :load_epic

  def show
    @graph_depth = graph_depth
    @graph = EpicDependencyGraphRenderer.new(@epic, depth: @graph_depth).render
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

  def graph
    @graph_depth = graph_depth
    @graph = EpicDependencyGraphRenderer.new(@epic, depth: @graph_depth).render
    html = render_to_string(partial: "dependency_graph", locals: {
      epic: @epic,
      result: @graph,
      initially_open: true,
      drawer: ActiveModel::Type::Boolean.new.cast(params[:drawer])
    })
    render html: helpers.turbo_frame_tag("epic_graph_drawer_body") { html.html_safe }
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

  def graph_depth
    params[:graph_depth].to_s == "transitive" ? :transitive : :adjacent
  end
end
