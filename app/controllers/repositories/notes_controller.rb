class Repositories::NotesController < ApplicationController
  before_action :load_repository

  def create
    body = params.dig(:repository_note, :body).to_s.strip
    if body.blank?
      redirect_to repository_path(@repository), alert: "Note cannot be blank."
      return
    end

    @repository.repository_notes.create!(body: body, author: "operator")
    redirect_to repository_path(@repository), notice: "Repository note pinned."
  end

  def destroy
    note = @repository.repository_notes.active.find(params[:id])
    note.remove!
    redirect_to repository_path(@repository), notice: "Repository note removed."
  end

  private

  def load_repository
    @repository = Current.user.repositories.find(params[:repository_id])
  end
end
