module Api
  module V1
    module App
      class RepositoryDocumentsController < BaseController
        def index
          repository = find_repository
          render json: documents_payload(repository)
        end

        def create
          repository = find_repository
          document = repository.repository_documents.new(document_params)
          document.user = Current.user

          if document.save
            render json: documents_payload(repository.reload).merge(message: "Document added."), status: :created
          else
            render_error("validation_failed", document.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end

        def destroy
          document = find_document
          repository = document.attachable
          document.file.purge if document.file.attached?
          document.destroy!

          render json: documents_payload(repository.reload).merge(message: "Document removed.")
        end

        private

        def documents_payload(repository)
          {
            repository: repository_json(repository),
            tabs: repository_tabs_json(repository),
            documents: repository
              .repository_documents
              .includes(:user, file_attachment: :blob)
              .newest_first
              .map { |document| document_json(document) },
            accepted_file_content_types: Document::ACCEPTED_FILE_CONTENT_TYPES
          }
        end

        def repository_tabs_json(repository)
          [
            { key: "overview", label: "Overview", path: repository_path(repository) },
            { key: "github_issues", label: "GitHub Issues", path: repository_path(repository, tab: "github_issues") },
            { key: "documents", label: "Documents", path: repository_documents_path(repository) },
            { key: "scheduled_tasks", label: "Scheduled Tasks", path: repository_scheduled_tasks_path(repository) }
          ]
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            repository_path: repository_path(repository)
          }
        end

        def document_json(document)
          {
            id: document.id,
            kind: document.kind,
            title: document.title,
            google_doc_url: document.google_docs_url,
            filename: document.filename,
            content_type: document.content_type,
            byte_size: document.byte_size,
            uploaded_by: document.user&.display_name,
            created_at: document.created_at.iso8601
          }
        end

        def find_repository
          Current.user.repositories.find(params[:repository_id])
        end

        def find_document
          Document.where(attachable_type: "Repository", attachable_id: Current.user.repositories.select(:id))
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
    end
  end
end
