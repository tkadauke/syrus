module Api
  module V1
    module App
      class DesignDocsController < BaseController
        def index
          render json: { design_docs: scoped_design_docs.map { |design_doc| serializer.summary(design_doc) } }
        end

        def repository_index
          repository = Repository.accessible_to(Current.user).find(params[:repository_id])
          design_docs = scoped_design_docs.joins(:design_doc_repositories)
            .where(design_doc_repositories: { repository_id: repository.id })

          render json: {
            repository: repository_json(repository),
            design_docs: design_docs.map { |design_doc| serializer.summary(design_doc) }
          }
        end

        def show
          render json: { design_doc: serializer.detail(find_design_doc) }
        end

        def create
          result = ::DesignDocs::Create.call(user: Current.user, attributes: design_doc_params.to_h.symbolize_keys)
          render json: { design_doc: serializer.detail(result.design_doc), message: "Design doc created." }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def update
          design_doc = find_design_doc
          result = ::DesignDocs::Update.call(
            design_doc: design_doc,
            user: Current.user,
            attributes: design_doc_params.to_h.symbolize_keys,
            actor_kind: design_doc_actor_kind
          )

          payload = { design_doc: serializer.detail(result.design_doc), mode: result.mode, message: update_message(result) }
          payload[:version] = serializer.version(result.version) if result.version
          payload[:suggestion] = serializer.suggestion(result.suggestion) if result.suggestion
          render json: payload
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue Pundit::NotAuthorizedError
          render_error("forbidden", "You are not allowed to edit this design doc.", status: :forbidden)
        end

        def versions
          design_doc = find_design_doc
          render json: {
            design_doc: serializer.summary(design_doc),
            versions: design_doc.versions.includes(:actor_user).order(version_number: :desc).map { |version| serializer.version(version) }
          }
        end

        private

        def scoped_design_docs
          policy_scope(DesignDoc).includes(:owner_user, :current_version, :repositories).newest_first
        end

        def find_design_doc
          scoped_design_docs.find(params[:id])
        end

        def serializer
          ::DesignDocs::Serializer
        end

        def update_message(result)
          return "Suggestion created." if result.suggestion
          return "Design doc updated." if result.version

          "Design doc metadata updated."
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            repository_path: repository_path(repository)
          }
        end

        def design_doc_actor_kind
          authenticated_bearer_token_request? ? "agent" : "user"
        end

        def design_doc_params
          params.require(:design_doc).permit(
            :title,
            :markdown,
            :visibility,
            :state,
            :origin_chat_session_id,
            :change_summary,
            :start_offset,
            :end_offset,
            :selected_markdown,
            repository_ids: [],
            collaborator_user_ids: []
          )
        end
      end
    end
  end
end
