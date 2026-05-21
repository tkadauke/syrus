class SmartFoldersController < ApplicationController
  before_action :set_smart_folder, only: %i[ update destroy ]

  def index
    @subject_type = subject_type_param
    @smart_folders = SmartFolder.for_user(Current.user, subject: @subject_type)
  end

  def create
    subject_type = subject_type_param

    # The save-as-folder form serializes the current filter tree into
    # a single `filter` JSON field. Fall back to the legacy URL form
    # when `filter` isn't present so a stray POST doesn't 500.
    tree = parsed_filter_tree
    filter_ast = ::Filters::Ast.parse(tree || filter_class_for(subject_type).from_params(params, user: Current.user).to_h)
    filter = ::Filters::Ast.serialize(filter_ast)

    if filter_ast.is_a?(::Filters::Ast::AndNode) && filter_ast.children.empty?
      redirect_to smart_folder_redirect_path(subject_type), alert: "Choose at least one filter before saving a smart folder."
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
      redirect_to smart_folder_redirect_path(subject_type, folder), notice: "Smart folder saved."
    else
      redirect_to smart_folder_redirect_path(subject_type), alert: folder.errors.full_messages.to_sentence
    end
  rescue ArgumentError => e
    redirect_to smart_folder_redirect_path(subject_type_param), alert: "Couldn't save filter: #{e.message}"
  end

  def update
    if @smart_folder.update(smart_folder_params)
      redirect_to smart_folders_path, notice: "Smart folder updated."
    else
      redirect_to smart_folders_path, alert: @smart_folder.errors.full_messages.to_sentence
    end
  end

  def destroy
    @smart_folder.destroy!
    redirect_to smart_folders_path, notice: "Smart folder deleted."
  end

  private

  def set_smart_folder
    @smart_folder = Current.user.smart_folders.find(params[:id])
  end

  def smart_folder_params
    params.require(:smart_folder).permit(:name, :position)
  end

  def parsed_filter_tree
    raw = params[:filter]
    return nil if raw.blank?

    JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end

  def subject_type_param
    subject_type = params[:subject_type].presence || "job"
    SmartFolder::SUBJECT_TYPES.include?(subject_type.to_s) ? subject_type.to_s : "job"
  end

  def filter_class_for(subject_type)
    case subject_type
    when "epic" then Epics::Filter
    when "workflow" then Workflows::Filter
    else Jobs::Filter
    end
  end

  def smart_folder_redirect_path(subject_type, folder = nil)
    options = folder ? { smart_folder_id: folder.id } : {}

    case subject_type
    when "epic" then epics_path(options)
    when "workflow" then dashboard_workflows_path(options)
    else dashboard_jobs_path(options)
    end
  end

  def next_position(subject_type)
    (Current.user.smart_folders.for_subject(subject_type).maximum(:position) || -1) + 1
  end
end
