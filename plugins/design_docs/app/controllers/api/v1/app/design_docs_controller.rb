module Api
  module V1
    module App
      class DesignDocsController < BaseController
        include RepositoryTabsSerialization

        before_action :require_design_docs_enabled

        def index
          render json: design_docs_payload(scoped_design_docs)
        end

        def repository_index
          repository = Repository.accessible_to(Current.user).find(params[:repository_id])
          design_docs = scoped_design_docs.joins(:design_doc_repositories)
            .where(design_doc_repositories: { repository_id: repository.id })

          render json: design_docs_payload(design_docs).merge(
            repository: repository_json(repository),
            tabs: repository_tabs_json(repository)
          )
        end

        def show
          render json: { design_doc: serializer.detail(ensure_suggestion_threads(find_design_doc), user: Current.user) }
        end

        def preview
          design_doc = policy_scope(DesignDoc).find(params[:id])
          render json: { design_doc: serializer.preview(design_doc) }
        rescue ActiveRecord::RecordNotFound
          render json: { design_doc: serializer.unavailable_preview(params[:id]) }
        end

        def preferences
          columns = normalize_design_doc_visible_columns_param(design_doc_visible_columns_param)
          if columns
            Current.user.update_dashboard_columns!(
              subject: ::DesignDocs::SmartFolders::SUBJECT,
              columns: columns
            )
          end

          render json: {
            message: "Design Docs preferences updated.",
            preferences: design_doc_preferences
          }
        rescue ActionController::ParameterMissing, ArgumentError => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        end

        def create
          result = ::DesignDocs::Create.call(user: Current.user, attributes: design_doc_params.to_h.symbolize_keys)
          render json: { design_doc: serializer.detail(result.design_doc, user: Current.user), message: "Design doc created." }, status: :created
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

          payload = { design_doc: serializer.detail(result.design_doc, user: Current.user), mode: result.mode, message: update_message(result) }
          payload[:version] = serializer.version(result.version) if result.version
          payload[:suggestion] = serializer.suggestion(result.suggestion) if result.suggestion
          render json: payload
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue Pundit::NotAuthorizedError
          render_error("forbidden", "You are not allowed to edit this design doc.", status: :forbidden)
        end

        def versions
          design_doc = find_design_doc_with_summary_associations
          render json: {
            design_doc: serializer.summary(design_doc),
            versions: design_doc.versions.includes(:actor_user).order(version_number: :desc).map { |version| serializer.version(version) }
          }
        end

        def version_threads
          design_doc = find_design_doc_with_summary_associations
          version = design_doc.versions.find(params[:version_id])
          anchor_ids = design_doc.anchors.active_as_of(version.version_number).select(:id)

          render json: {
            design_doc: serializer.summary(design_doc),
            version: serializer.version(version),
            threads: design_doc.threads
              .where(design_doc_anchor_id: anchor_ids)
              .includes(:anchor, comments: :author_user)
              .order(:created_at, :id)
              .map { |thread| serializer.thread(thread) },
            suggestions: design_doc.suggestions
              .where(design_doc_anchor_id: anchor_ids)
              .includes(:anchor, :suggested_by_user, :reviewed_by_user, thread: [ :anchor, { comments: :author_user } ])
              .order(created_at: :desc, id: :desc)
              .map { |suggestion| serializer.suggestion(suggestion) }
          }
        end

        def comments
          result = ::DesignDocs::CreateComment.call(
            design_doc: find_design_doc,
            user: Current.user,
            attributes: comment_params.to_h.symbolize_keys,
            actor_kind: design_doc_actor_kind
          )

          render json: {
            design_doc: serializer.detail(result.design_doc, user: Current.user),
            thread: serializer.thread(result.thread),
            comment: serializer.comment(result.comment),
            version: result.version ? serializer.version(result.version) : nil,
            message: "Comment created."
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue Pundit::NotAuthorizedError
          render_error("forbidden", "You are not allowed to comment on this design doc.", status: :forbidden)
        end

        def resolve_thread
          design_doc = find_design_doc
          result = ::DesignDocs::ResolveThread.call(
            thread: design_doc.threads.find(params[:thread_id]),
            user: Current.user
          )

          render json: { thread: serializer.thread(result.thread), message: "Comment thread resolved." }
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue Pundit::NotAuthorizedError
          render_error("forbidden", "Only the owner can resolve design doc comments.", status: :forbidden)
        end

        def create_suggestion
          result = ::DesignDocs::CreateSuggestion.call(
            design_doc: find_design_doc,
            user: Current.user,
            attributes: suggestion_params.to_h.symbolize_keys,
            actor_kind: design_doc_actor_kind
          )

          payload = {
            design_doc: serializer.detail(result.design_doc, user: Current.user),
            suggestion: serializer.suggestion(result.suggestion),
            message: "Suggestion created."
          }
          payload[:version] = serializer.version(result.version) if result.version
          render json: payload, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue Pundit::NotAuthorizedError
          render_error("forbidden", "You are not allowed to suggest changes to this design doc.", status: :forbidden)
        end

        def accept_suggestion
          result = review_suggestion(:accept)
          status = result.applied ? :ok : :conflict

          payload = { design_doc: serializer.detail(result.design_doc, user: Current.user), suggestion: serializer.suggestion(result.suggestion), message: suggestion_review_message(result) }
          payload[:version] = serializer.version(result.version) if result.version
          render json: payload, status: status
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue Pundit::NotAuthorizedError
          render_error("forbidden", "Only the owner can review design doc suggestions.", status: :forbidden)
        end

        def reject_suggestion
          result = review_suggestion(:reject)

          render json: {
            design_doc: serializer.detail(result.design_doc, user: Current.user),
            suggestion: serializer.suggestion(result.suggestion),
            message: "Suggestion rejected."
          }
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue Pundit::NotAuthorizedError
          render_error("forbidden", "Only the owner can review design doc suggestions.", status: :forbidden)
        end

        private

        def require_design_docs_enabled
          return if ::DesignDocs.enabled?

          render_error("plugin_disabled", "The design_docs plugin is disabled.", status: :not_found)
        end

        def scoped_design_docs
          default_list_scope(filtered_design_docs(policy_scope(DesignDoc)))
            .includes(:owner_user, :current_version, :repositories, :collaborator_users, threads: :comments)
            .newest_first
        end

        def design_docs_payload(scope)
          base_scope = policy_scope(DesignDoc)
          SmartFolder.ensure_builtins_for_subject!(::DesignDocs::SmartFolders::SUBJECT)

          {
            active_smart_folder_id: active_smart_folder&.id,
            filter: current_filter.to_h,
            filter_schema: ::Filters::Schema.for(subject: ::DesignDocs::SmartFolders::SUBJECT, user: Current.user),
            preferences: design_doc_preferences,
            controls: design_doc_controls,
            smart_folders: ::Admin::SmartFolderNavigation.new(
              subject: ::DesignDocs::SmartFolders::SUBJECT,
              user: Current.user,
              active_folder: active_smart_folder,
              base_scope: base_scope,
              filter_class: ::DesignDocs::Filter
            ).folders,
            design_docs: scope.map { |design_doc| serializer.summary(design_doc) }
          }
        end

        def design_doc_preferences
          {
            visible_columns: Current.user.dashboard_visible_columns(::DesignDocs::SmartFolders::SUBJECT),
            raw: Current.user.dashboard_preferences.fetch("design_docs", {})
          }
        end

        def design_doc_visible_columns_param
          body = request.request_parameters
          return body.dig("preferences", "visible_columns") if body.dig("preferences", "visible_columns")
          return body["visible_columns"] if body["visible_columns"]
          return params.dig(:preferences, :visible_columns) if params.dig(:preferences, :visible_columns)
          return params[:visible_columns] if params.key?(:visible_columns)

          nil
        end

        def normalize_design_doc_visible_columns_param(value)
          case value
          when ActionController::Parameters
            return normalize_design_doc_visible_columns_param(value[:visible_columns]) if value.key?(:visible_columns)

            hash = value.to_unsafe_h
            return hash.sort_by { |key, _| key.to_i }.map(&:last) if hash.keys.all? { |key| key.to_s.match?(/\A\d+\z/) }

            value
          when Hash
            return normalize_design_doc_visible_columns_param(value["visible_columns"] || value[:visible_columns]) if value.key?("visible_columns") || value.key?(:visible_columns)
            return value.sort_by { |key, _| key.to_i }.map(&:last) if value.keys.all? { |key| key.to_s.match?(/\A\d+\z/) }

            value
          else
            value
          end
        end

        def design_doc_controls
          {
            columns: {
              required: design_doc_column_options(User::DASHBOARD_REQUIRED_COLUMNS.fetch("design_docs")),
              optional: design_doc_column_options(User::DASHBOARD_OPTIONAL_COLUMNS.fetch("design_docs"))
            }
          }
        end

        def design_doc_column_options(columns)
          columns.map { |column| { key: column, title: design_doc_column_label(column) } }
        end

        def design_doc_column_label(column)
          {
            "title" => "Title",
            "doc_slug" => "DOC",
            "state" => "State",
            "repository" => "Repository",
            "owner" => "Owner",
            "collaborators" => "Collaborators",
            "comments" => "Comments",
            "latest_version" => "Latest version",
            "updated_at" => "Updated",
            "actions" => "Actions"
          }.fetch(column, column.to_s.humanize)
        end

        def filtered_design_docs(scope)
          current_filter.apply(scope)
        end

        def default_list_scope(scope)
          return scope if active_smart_folder
          return scope if filter_mentions_field?(current_filter.to_h, "state")

          scope.where.not(state: "archived")
        end

        def current_filter
          @current_filter ||= ::DesignDocs::Filter.from_params(params, smart_folder: active_smart_folder, user: Current.user)
        end

        def active_smart_folder
          @active_smart_folder ||= ::Admin::SmartFolderNavigation.active_folder(
            subject: ::DesignDocs::SmartFolders::SUBJECT,
            user: Current.user,
            params: params
          )
        end

        def find_design_doc
          policy_scope(DesignDoc).find(params[:id])
        end

        def find_design_doc_with_summary_associations
          policy_scope(DesignDoc)
            .includes(:owner_user, :current_version, :repositories, :collaborator_users, threads: :comments)
            .find(params[:id])
        end

        def serializer
          ::DesignDocs::Serializer
        end

        def ensure_suggestion_threads(design_doc)
          ::DesignDocs::EnsureSuggestionThreads.call(design_doc: design_doc)
        end

        def filter_mentions_field?(node, field)
          case node
          when Hash
            node["field"] == field || node.values.any? { |value| filter_mentions_field?(value, field) }
          when Array
            node.any? { |value| filter_mentions_field?(value, field) }
          else
            false
          end
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
            :checkpoint,
            :start_offset,
            :end_offset,
            :selected_markdown,
            repository_ids: [],
            collaborator_user_ids: []
          )
        end

        def comment_params
          params.require(:comment).permit(:body, :start_offset, :end_offset, :selected_markdown, :selected_text, :anchor_kind, :thread_id)
        end

        def suggestion_params
          params.require(:suggestion).permit(
            :start_offset,
            :end_offset,
            :selected_markdown,
            :selected_text,
            :original_markdown,
            :suggested_markdown,
            :proposed_markdown,
            :change_type,
            :change_summary,
            :thread_id,
            :run_id,
            :workflow_id,
            :chat_message_id,
            :design_doc_agent_run_id,
            :triggering_comment_id,
            :autosave
          )
        end

        def review_suggestion(decision)
          design_doc = find_design_doc
          suggestion = design_doc.suggestions.find(params[:suggestion_id])
          if decision == :accept
            ::DesignDocs::ReviewSuggestion.accept(suggestion: suggestion, user: Current.user)
          else
            ::DesignDocs::ReviewSuggestion.reject(suggestion: suggestion, user: Current.user)
          end
        end

        def suggestion_review_message(result)
          return "Suggestion accepted." if result.applied

          result.suggestion.conflict_reason.presence || "Suggestion can no longer be applied."
        end
      end
    end
  end
end
