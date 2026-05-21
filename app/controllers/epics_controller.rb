class EpicsController < ApplicationController
  PER_PAGE = 25

  before_action :load_epic, except: :index

  def index
    SmartFolder.ensure_builtins!
    SmartFolder.ensure_epic_builtins!
    @page = [ params[:page].to_i, 1 ].max
    @smart_folder = smart_folder_from_params
    @filter = ::Epics::Filter.from_params(params, smart_folder: @smart_folder, user: Current.user)
    @schema = ::Filters::Schema.for(subject: :epic, user: Current.user)
    @smart_folders = SmartFolder.for_subject(:epic).where(user: Current.user).order(:position, :id)
    @builtin_smart_folders = SmartFolder.for_subject(:epic).built_in_sidebar_order
    @smart_folder_counts = smart_folder_counts(Current.user.epics)
    @primary_builtin_smart_folders, @more_builtin_smart_folders = split_builtin_smart_folders

    @epics = @filter.apply(Current.user.epics.includes(:repository))
    @epics_total = @epics.count
    @epics = @epics.order(updated_at: :desc, id: :desc).offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  def show
    @graph = EpicDependencyGraphRenderer.new(@epic).render
    @jobs = @epic.jobs.includes(:repository, :dependencies, :dependent_links).order(:id)
  end

  def archive
    if @epic.archived?
      redirect_back fallback_location: epics_path, notice: "Epic already archived."
    else
      @epic.archive!
      redirect_to epics_path, notice: "Epic archived."
    end
  end

  def update_state
    target_state = params[:target_state].to_s

    if ActiveModel::Type::Boolean.new.cast(params[:override])
      @epic.override_state!(target_state)
      respond_to_state_update
    elsif @epic.ready? && target_state == "in_progress"
      @epic.start!
      respond_to_state_update
    elsif @epic.in_progress? && target_state == "ready"
      @epic.unstart!
      respond_to_state_update
    else
      respond_to do |format|
        format.html { redirect_back fallback_location: dashboard_epics_path, alert: "That Epic transition is not available from the board." }
        format.json { render json: { error: "transition_not_allowed" }, status: :unprocessable_content }
      end
    end
  rescue ArgumentError
    respond_to do |format|
      format.html { redirect_back fallback_location: dashboard_epics_path, alert: "Unknown Epic state." }
      format.json { render json: { error: "unknown_state" }, status: :unprocessable_content }
    end
  end

  def graph
    @graph = EpicDependencyGraphRenderer.new(@epic).render
    html = render_to_string(partial: "dependency_graph", locals: {
      epic: @epic,
      result: @graph,
      initially_open: true,
      drawer: ActiveModel::Type::Boolean.new.cast(params[:drawer])
    })
    render html: helpers.safe_turbo_frame("epic_graph_drawer_body") { html.html_safe }
  end

  private

  def smart_folder_from_params
    return if params[:smart_folder_id].blank?

    SmartFolder.for_subject(:epic).builtin.where(user_id: nil).find_by(id: params[:smart_folder_id]) ||
      SmartFolder.for_subject(:epic).where(user: Current.user).find_by(id: params[:smart_folder_id])
  end

  def smart_folder_counts(base_scope)
    (@builtin_smart_folders + @smart_folders).to_h do |folder|
      [ folder.id, ::Epics::Filter.from_tree(folder.filter, user: Current.user).apply(base_scope).count ]
    end
  end

  def split_builtin_smart_folders
    primary = []
    more = []

    @builtin_smart_folders.each do |folder|
      case folder.visibility
      when :always
        primary << folder
      when :on_demand
        more << folder
      when :when_present
        primary << folder if @smart_folder_counts[folder.id].to_i.positive? || @smart_folder == folder
      else
        primary << folder
      end
    end

    [ primary, more ]
  end

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
