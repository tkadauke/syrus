class SmartFoldersController < ApplicationController
  before_action :set_smart_folder, only: %i[ update destroy ]

  def index
    @smart_folders = SmartFolder.for_user(Current.user)
  end

  def create
    filter = Jobs::Filter.new(params.permit(:state, :repository_id, :pr, :age, :attention).to_h).to_h
    if filter.empty?
      redirect_to root_path, alert: "Choose at least one filter before saving a smart folder."
      return
    end

    folder = Current.user.smart_folders.new(
      name: smart_folder_params[:name],
      kind: "user_defined",
      filter: filter,
      position: next_position
    )

    if folder.save
      redirect_to root_path(smart_folder_id: folder.id), notice: "Smart folder saved."
    else
      redirect_to root_path(filter), alert: folder.errors.full_messages.to_sentence
    end
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

  def next_position
    (Current.user.smart_folders.maximum(:position) || -1) + 1
  end
end
