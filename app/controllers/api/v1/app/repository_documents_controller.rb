module Api
  module V1
    module App
      class RepositoryDocumentsController < BaseController
        include RepositoryTabsSerialization
        PER_PAGE = 25
        def index
          repository = find_repository
          render json: documents_payload(repository)
        end

        def create
          repository = find_writable_repository
          return unless repository

          document = repository.repository_documents.new(document_params)
          document.user = Current.user

          if document.save
            render json: { document: document_json(document), message: I18n.t("api.repository_documents.added") }, status: :created
          else
            render_error("validation_failed", document.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end

        def destroy
          document = find_document
          repository = document.attachable
          return unless authorize_repository_write!(repository)

          document.file.purge if document.file.attached?
          document.destroy!

          render json: { id: document.id, message: I18n.t("api.repository_documents.removed") }
        end

        def file
          document = find_document
          raise ActiveRecord::RecordNotFound, "Document file not found" unless document.file.attached?

          send_secure_blob(document.file.blob, immutable: true)
        end

        private

        def documents_payload(repository)
          page = [ params.fetch(:page, 1).to_i, 1 ].max
          scope = repository.repository_documents.includes(:user, file_attachment: :blob).newest_first
          total = scope.count
          {
            repository: repository_json(repository),
            can_write: RepositoryPolicy.new(Current.user, repository).write?,
            tabs: repository_tabs_json(repository),
            documents: scope.offset((page - 1) * PER_PAGE).limit(PER_PAGE).map { |document| document_json(document) },
            pagination: { page: page, per_page: PER_PAGE, total: total, total_pages: (total.to_f / PER_PAGE).ceil }
          }
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
            created_at: document.created_at.iso8601,
            file_path: document.file.attached? ? "/api/v1/app/repository_documents/#{document.id}/file" : nil
          }
        end

        def find_repository
          find_readable_repository
        end

        def find_document
          Document.where(attachable_type: "Repository", attachable_id: readable_repository_scope.select(:id))
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
