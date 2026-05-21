class SmartFoldersController < ApplicationController
  before_action :set_smart_folder, only: %i[ update destroy ]

  def index
    @subject_type = smart_folder_subject
    @smart_folders = SmartFolder.for_user(Current.user, subject: @subject_type)
  end

  def create
    subject_type = smart_folder_subject

    # The save-as-folder form serializes the current filter tree into
    # a single `filter` JSON field. Fall back to the legacy URL form
    # when `filter` isn't present so a stray POST doesn't 500.
    tree = parsed_filter_tree
    filter_ast = ::Filters::Ast.parse(tree || legacy_filter_tree(subject_type))
    filter = ::Filters::Ast.serialize(filter_ast)

    if filter_ast.is_a?(::Filters::Ast::AndNode) && filter_ast.children.empty?
      redirect_to dashboard_path_for(subject_type), alert: "Choose at least one filter before saving a smart folder."
      return
    end

    folder = Current.user.smart_folders.new(
      name: smart_folder_params[:name],
      kind: "user_defined",
      subject_type: subject_type,
      filter: filter,
      position: next_position(subject_type)
    )

    if folder.save
      redirect_to dashboard_path_for(subject_type, smart_folder_id: folder.id), notice: "Smart folder saved."
    else
      redirect_to dashboard_path_for(subject_type), alert: folder.errors.full_messages.to_sentence
    end
  rescue ArgumentError => e
    redirect_to dashboard_path_for(smart_folder_subject), alert: "Couldn't save filter: #{e.message}"
  end

  def update
    if @smart_folder.update(smart_folder_params)
      redirect_to smart_folders_path(subject_type: smart_folder_subject), notice: "Smart folder updated."
    else
      redirect_to smart_folders_path(subject_type: smart_folder_subject), alert: @smart_folder.errors.full_messages.to_sentence
    end
  end

  def destroy
    @smart_folder.destroy!
    redirect_to smart_folders_path(subject_type: smart_folder_subject), notice: "Smart folder deleted."
  end

  private

  def set_smart_folder
    @smart_folder = Current.user.smart_folders.find(params[:id])
  end

  def smart_folder_params
    params.require(:smart_folder).permit(:name, :position)
  end

  def smart_folder_subject
    params[:subject_type].to_s.presence_in(SmartFolder::SUBJECT_TYPES) || "job"
  end

  def legacy_filter_tree(subject_type)
    case subject_type
    when "workflow"
      Workflows::Filter.from_params(params).to_h
    when "epic"
      Epics::Filter.from_params(params).to_h
    else
      Jobs::Filter.from_params(params).to_h
    end
  end

  def dashboard_path_for(subject_type, **query)
    case subject_type
    when "workflow"
      dashboard_workflows_path(query)
    when "epic"
      dashboard_epics_path(query)
    else
      dashboard_jobs_path(query)
    end
  end

  def parsed_filter_tree
    raw = params[:filter]
    return nil if raw.blank?

    JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end

  def next_position(subject_type)
    (Current.user.smart_folders.where(subject_type: subject_type).maximum(:position) || -1) + 1
  end
end
