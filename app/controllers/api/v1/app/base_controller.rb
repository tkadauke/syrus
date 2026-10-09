module Api
  module V1
    module App
      # JSON API for the browser SPA and app-scoped CLI calls. Browser
      # requests use session cookies; CLI requests may use bearer tokens.
      class BaseController < ApplicationController
        include Pundit::Authorization
        include JobEpicRefFinder
        include JsonErrorRendering

        TokenSession = Struct.new(:user, :invocation_context, keyword_init: true) do
          def destroy; end
        end

        skip_before_action :compute_system_alerts
        skip_forgery_protection if: :authenticated_bearer_token_request?
        around_action :audit_internal_cli_invocation
        before_action :enforce_invocation_context_scope
        before_action :authorize_machine_invocation_context
        before_action :authorize_internal_cli_invocation

        rescue_from ActiveRecord::RecordNotFound do |e|
          render_error("not_found", e.message, status: :not_found)
        end

        rescue_from ActionController::ParameterMissing do |e|
          render_error("bad_request", e.message, status: :bad_request)
        end

        private

        def resume_session
          resume_api_token_session || super
        end

        def resume_api_token_session
          token_session = bearer_token_session
          return unless token_session

          Current.session = token_session
        end

        def authenticated_bearer_token_request?
          bearer_token_session.present?
        end

        def bearer_token_session
          token = request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]
          return if token.blank?

          @bearer_token_session ||= begin
            if (user = User.find_by(api_token: token))
              TokenSession.new(user: user)
            elsif (context = bearer_token_invocation_context(token))
              TokenSession.new(user: context.user, invocation_context: context)
            end
          end
        end

        def bearer_token_invocation_context(token)
          McpInvocationContext.resolve_for_app_api(token).tool_context
        rescue McpInvocationContext::InvalidContext
          nil
        end

        def request_authentication
          render_error("unauthorized", I18n.t("api.base.sign_in_required"), status: :unauthorized)
        end

        def policy_scope(scope, policy_scope_class: nil)
          restrict_invocation_relation(super)
        end

        def restrict_invocation_relation(relation)
          context = current_invocation_context
          return relation unless context && relation.respond_to?(:klass)

          case relation.klass.name
          when "Job"
            relation = relation.where(repository_id: context.allowed_repository_ids) if context.allowed_repository_ids.present?
            relation = relation.where(id: context.run? ? context.job.id : context.allowed_job_ids) if context.run? || context.allowed_job_ids
          when "Repository"
            relation = relation.where(id: context.allowed_repository_ids) if context.allowed_repository_ids.present?
          when "Epic"
            relation = relation.where(repository_id: context.allowed_repository_ids) if context.allowed_repository_ids.present?
          when "Workflow"
            relation = relation.joins(:job).where(jobs: { repository_id: context.allowed_repository_ids }) if context.allowed_repository_ids.present?
            relation = relation.where(id: context.run? ? context.workflow.id : context.allowed_workflow_ids) if context.run? || context.allowed_workflow_ids
          when "Run"
            relation = relation.joins(:job).where(jobs: { repository_id: context.allowed_repository_ids }) if context.allowed_repository_ids.present?
            relation = relation.where(id: context.run? ? context.run.id : context.allowed_run_ids) if context.run? || context.allowed_run_ids
          when "ChatSession"
            relation = relation.where(id: context.chat? ? context.chat_session.id : context.allowed_chat_session_ids) if context.chat? || context.allowed_chat_session_ids
          end

          relation
        end

        def invocation_scoped_chat_scope(scope)
          context = current_invocation_context
          return scope unless context
          return scope.none if context.run?

          scope.where(id: context.chat_session.id)
        end

        def invocation_scoped_repository_scope(scope)
          context = current_invocation_context
          return scope unless context

          repository_ids = context.allowed_repository_ids
          repository_ids = [ context.repository.id ].compact if repository_ids.blank? && context.repository
          repository_ids.present? ? scope.where(id: repository_ids) : scope.none
        end

        def enforce_invocation_context_scope
          context = current_invocation_context
          return true unless context

          if disallowed_invocation_param?(context)
            render_error(
              "forbidden",
              "This Syrus invocation context is scoped to the current run or chat and cannot access that resource.",
              status: :forbidden
            )
            return false
          end

          true
        end

        def authorize_internal_cli_invocation
          invocation = current_internal_cli_invocation
          return true unless invocation
          return true if invocation.allowed?

          render_error("forbidden", AppApi::InternalCliInvocation::DENIED_MESSAGE, status: :forbidden)
          false
        end

        def audit_internal_cli_invocation
          yield
        ensure
          current_internal_cli_invocation&.audit(status: response.status)
        end

        def current_internal_cli_invocation
          return @current_internal_cli_invocation if defined?(@current_internal_cli_invocation)

          context = current_invocation_context
          @current_internal_cli_invocation =
            context && (context.run? || context.chat?) ? AppApi::InternalCliInvocation.new(self, context: context) : nil
        end

        def current_invocation_context
          session = Current.session
          session.invocation_context if session.respond_to?(:invocation_context)
        end

        def disallowed_invocation_param?(context)
          invocation_param_id(:repository_id).then { |id| return true if id && context.allowed_repository_ids.present? && !context.allowed_repository_ids.include?(id) }
          invocation_param_id(:job_id).then { |id| return true if id && context.allowed_job_ids && !context.allowed_job_ids.include?(id) }
          invocation_param_id(:workflow_id).then { |id| return true if id && context.allowed_workflow_ids && !context.allowed_workflow_ids.include?(id) }
          invocation_param_id(:run_id).then { |id| return true if id && context.allowed_run_ids && !context.allowed_run_ids.include?(id) }
          invocation_param_id(:chat_id).then { |id| return true if id && context.allowed_chat_session_ids && !context.allowed_chat_session_ids.include?(id) }
          return true if context.chat? && params[:id].present? && controller_path.end_with?("/chats") && invocation_param_id(:id) != context.chat_session.id
          false
        end

        def authorize_machine_invocation_context
          context = current_invocation_context
          return true unless context&.macos_worker?
          return true if McpInvocationContext::MACOS_WORKER_UPDATE_PATHS.include?(request.path)

          render_error(
            "forbidden",
            "This Syrus machine credential is scoped to macOS worker update endpoints.",
            status: :forbidden
          )
          false
        end

        def invocation_param_id(key)
          Integer(params[key], exception: false) if params[key].present?
        end

        def require_admin
          return if Current.user&.admin?

          render_error("forbidden", I18n.t("api.base.admin_forbidden"), status: :forbidden)
        end

        # Shared gate for Job mutation actions (approve, retry, cancel,
        # submit chat feedback, priority/provider-setting changes): the
        # creator, a global admin, or a write-tier-or-higher
        # RepositoryMembership on the Job's repository. Callers typically
        # find the job through the wider, repository-membership-based
        # JobPolicy::Scope first (so a visible-but-not-writable Job 403s
        # here instead of 404ing at the finder).
        def authorize_job_mutation!(job)
          return true if JobPolicy.new(Current.user, job).write?

          render_error("forbidden", "Only the job owner, a repository member with write access, or an admin can perform this action.", status: :forbidden)
          false
        end

        # Same write-tier gate as JobPolicy#write?'s repository half, for
        # actions (like Coding Mode's `!` shell command execution) that act
        # directly on a repository checkout rather than an existing Job.
        def authorize_repository_write!(repository)
          return true if RepositoryPolicy.new(Current.user, repository).write?

          render_error("forbidden", "Only a repository member with write access, or an admin, can perform this action.", status: :forbidden)
          false
        end

        def authorize_repository_admin!(repository)
          return true if RepositoryPolicy.new(Current.user, repository).admin?

          render_error("forbidden", "Only a repository admin can perform this action.", status: :forbidden)
          false
        end

        def plain_json(value)
          case value
          when ActionController::Parameters
            plain_json(value.to_unsafe_h)
          when Hash
            value.to_h.transform_values { |child| plain_json(child) }
          when Array
            value.map { |child| plain_json(child) }
          else
            value
          end
        end
      end
    end
  end
end
