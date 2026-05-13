class Repositories::DocumentsController < ApplicationController
  before_action :load_repository, only: %i[ index create ]
  before_action :load_document, only: :destroy

  def index
    @documents = @repository.repository_documents.includes(:user, file_attachment: :blob).newest_first
    @document = @repository.repository_documents.new(kind: "file")
    render layout: false if params[:frame].present?
  end

  def create
    @document = @repository.repository_documents.new(document_params)
    @document.user = Current.user

    if @document.save
      redirect_to repository_documents_path(@repository, frame: params[:frame]), notice: "Document added."
    else
      @documents = @repository.repository_documents.includes(:user, file_attachment: :blob).newest_first
      flash.now[:alert] = @document.errors.full_messages.to_sentence
      render :index, status: :unprocessable_entity, layout: false
    end
  end

  def destroy
    repository = @document.repository
    @document.file.purge if @document.file.attached?
    @document.destroy!
    redirect_to repository_documents_path(repository, frame: params[:frame]), notice: "Document removed."
  end

  private

  def load_repository
    @repository = Current.user.repositories.find(params[:repository_id])
  end

  def load_document
    @document = RepositoryDocument.joins(:repository)
      .where(repositories: { user_id: Current.user.id })
      .find(params[:id])
  end

  def document_params
    params.require(:repository_document).permit(:kind, :title, :google_docs_url, :file)
  end
end
