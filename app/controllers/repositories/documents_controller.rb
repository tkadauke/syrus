class Repositories::DocumentsController < ApplicationController
  before_action :load_repository, only: %i[ index create ]
  before_action :load_document, only: :destroy

  def index
    @documents = @repository.repository_documents.includes(:user, file_attachment: :blob).newest_first
    @document = @repository.repository_documents.new(kind: "file", user: Current.user)
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
      render :index, status: :unprocessable_content, layout: false
    end
  end

  def destroy
    repository = @document.attachable
    @document.file.purge if @document.file.attached?
    @document.destroy!
    redirect_to repository_documents_path(repository, frame: params[:frame]), notice: "Document removed."
  end

  private

  def load_repository
    @repository = Current.user.repositories.find(params[:repository_id])
  end

  def load_document
    @document = Document.where(attachable_type: "Repository", attachable_id: Current.user.repositories.select(:id))
      .find(params[:id])
  end

  def document_params
    params.require(document_param_key).permit(:kind, :title, :google_doc_url, :google_docs_url, :file)
  end

  def document_param_key
    return :repository_document if params[:repository_document].present?

    :document
  end
end
