module Api
  module V1
    module Admin
      # Bearer-token admin surface for design docs : the same
      # write paths the app API uses, exposed under `/api/v1/admin/*` for
      # operators/orchestrators instead of borrowing the SPA's
      # session-shaped app API with an admin token.
      class DesignDocsController < BaseController
        before_action :require_design_docs_enabled

        # ?state=draft|accepted|archived
        # ?visibility=private|public
        # ?user=substring         — match owner User#email_address
        def index
          scope = ::DesignDocs::DesignDoc.includes(:owner_user, :current_version, :repositories).newest_first
          scope = scope.where(state: params[:state]) if params[:state].present?
          scope = scope.where(visibility: params[:visibility]) if params[:visibility].present?
          if params[:user].present?
            scope = scope.joins(:owner_user).where("users.email_address LIKE ?", "%#{params[:user]}%")
          end
          design_docs = scope.limit(50)

          render json: { count: design_docs.size, design_docs: design_docs.map { |doc| serialize_summary(doc) } }
        end

        def show
          render json: { design_doc: serialize_detail(find_design_doc) }
        end

        def create
          result = ::DesignDocs::Create.call(user: current_api_user, attributes: design_doc_params.to_h.symbolize_keys)
          render json: { design_doc: serialize_detail(result.design_doc) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def update
          design_doc = find_design_doc
          result = ::DesignDocs::Update.call(
            design_doc: design_doc,
            user: current_api_user,
            attributes: update_attributes,
            actor_kind: "user"
          )

          payload = { design_doc: serialize_detail(result.design_doc), mode: result.mode }
          payload[:version] = serialize_version(result.version) if result.version
          payload[:suggestion] = ::DesignDocs::Serializer.suggestion(result.suggestion) if result.suggestion
          render json: payload
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue Pundit::NotAuthorizedError
          render_error("forbidden", "You are not allowed to edit this design doc.", status: :forbidden)
        end

        def versions
          design_doc = find_design_doc
          render json: {
            design_doc: serialize_summary(design_doc),
            versions: design_doc.versions.includes(:actor_user).order(version_number: :desc).map { |version| serialize_version(version) }
          }
        end

        private

        def require_design_docs_enabled
          return if ::DesignDocs.enabled?

          render_error("plugin_disabled", "The design_docs plugin is disabled.", status: :not_found)
        end

        def find_design_doc
          ::DesignDocs::DesignDoc.find(params[:id])
        end

        # Every operator PATCH is a deliberate, one-shot change (there is no
        # autosave concept over this API), so it always checkpoints —
        # matching the acceptance bar that updating through the admin API
        # produces a version row the same way an explicit `Save` does on
        # the app path.
        def update_attributes
          attrs = design_doc_params.to_h.symbolize_keys
          attrs[:checkpoint] = true unless attrs.key?(:checkpoint)
          attrs
        end

        # Accepts either a nested `design_doc: { ... }` body (matching the
        # app API) or a flat body, so operator scripts don't need to know
        # the SPA's request shape.
        def design_doc_params
          source = params[:design_doc].present? ? params.require(:design_doc) : params
          source.permit(:title, :markdown, :visibility, :state, :change_summary, :checkpoint)
        end

        def serialize_summary(design_doc)
          ::DesignDocs::Serializer.summary(design_doc)
        rescue => e
          ::Admin::JobStateSerializer.per_record_error(design_doc, e)
        end

        def serialize_detail(design_doc)
          ::DesignDocs::Serializer.detail(design_doc, user: current_api_user)
        rescue => e
          ::Admin::JobStateSerializer.per_record_error(design_doc, e)
        end

        def serialize_version(version)
          ::DesignDocs::Serializer.version(version)
        rescue => e
          ::Admin::JobStateSerializer.per_record_error(version, e)
        end
      end
    end
  end
end
