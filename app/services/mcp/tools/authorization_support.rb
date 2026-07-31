module Mcp::Tools
  # Resource scoping convention for chat MCP tools:
  # - Jobs: scope through current_user.jobs, further restricted by context.allowed_job_ids when set.
  # - Epics: scope through current_user.epics.
  # - Workflows and Runs: join through job.repository and require the repository
  #   to belong to current_user; further restricted by allowed_workflow_ids / allowed_run_ids.
  # - ChatSessions: scoped by user_id, further restricted by allowed_chat_session_ids.
  #
  # allowed_*_ids are nil by default (no additional restriction beyond user ownership).
  # They are populated by the McpToolContext when the surface restricts resource access —
  # for example, the future AGENT_INSIGHT role limits reads to a declared set of jobs.
  module AuthorizationSupport
    class AuthorizationError < StandardError; end

    module ToolDispatch
      def call(*args, server_context: nil, **kwargs, &block)
        Mcp::Tools::AuthorizationSupport.with_server_context(server_context) do
          super(*args, server_context: server_context, **kwargs, &block)
        end
      rescue Mcp::Tools::AuthorizationSupport::AuthorizationError
        Mcp::Tools.not_authorized
      end
    end

    class << self
      def current_server_context
        Thread.current[:mcp_tools_authorization_server_context]
      end

      def current_mcp_context
        Thread.current[:mcp_tools_tool_context]
      end

      def with_server_context(server_context)
        previous_ctx     = current_server_context
        previous_mcp_ctx = current_mcp_context
        Thread.current[:mcp_tools_authorization_server_context] = server_context
        Thread.current[:mcp_tools_tool_context] = nil  # cleared; built lazily on first access
        yield
      ensure
        Thread.current[:mcp_tools_authorization_server_context] = previous_ctx
        Thread.current[:mcp_tools_tool_context] = previous_mcp_ctx
      end
    end

    def admin? = current_user.admin?

    def current_user = chat_session.user

    def chat_session = server_context.fetch(:chat_session)

    def server_context
      Mcp::Tools::AuthorizationSupport.current_server_context || raise(KeyError, "server_context is required")
    end

    def find_job!(id, includes: nil)
      scope = admin? ? Job.all : current_user.jobs
      scope = scope.where(id: mcp_context.allowed_job_ids) if mcp_context&.allowed_job_ids
      scope = scope.includes(includes) if includes
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "job not found or not accessible"
    end

    def find_epic!(id, includes: nil)
      scope = admin? ? Epic.all : current_user.epics
      scope = scope.includes(includes) if includes
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "epic not found or not accessible"
    end

    def find_workflow!(id, includes: nil)
      scope = admin? ? Workflow.all : Workflow.joins(job: :repository).where(repositories: { user_id: current_user.id })
      scope = scope.where(id: mcp_context.allowed_workflow_ids) if mcp_context&.allowed_workflow_ids
      scope = scope.includes(includes) if includes
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "workflow not found or not accessible"
    end

    def find_run!(id)
      scope = admin? ? Run.all : Run.joins(step: { workflow: { job: :repository } }).where(repositories: { user_id: current_user.id })
      scope = scope.where(id: mcp_context.allowed_run_ids) if mcp_context&.allowed_run_ids
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "run not found or not accessible"
    end

    def find_chat_session!(id)
      scope = ChatSession.where(user_id: current_user.id)
      scope = scope.where(id: mcp_context.allowed_chat_session_ids) if mcp_context&.allowed_chat_session_ids
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "chat session not found or not accessible"
    end

    def authorize_resource!(resource, action: :read)
      return resource if admin?

      owner = resource.try(:user) || resource.try(:repository)&.user
      raise AuthorizationError, "not authorized" unless owner == current_user

      resource
    end

    private

    # Lazily-built McpToolContext for the current dispatch. Cleared at the start of
    # each with_server_context block so a fresh context is built per tool call.
    def mcp_context
      Thread.current[:mcp_tools_tool_context] ||= begin
        ctx = Mcp::Tools::AuthorizationSupport.current_server_context
        ctx ? McpToolContext.from_server_context(ctx) : nil
      end
    end
  end
end
