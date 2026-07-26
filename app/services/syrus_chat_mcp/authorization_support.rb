module SyrusChatMcp
  # Resource scoping convention for chat MCP tools:
  # - Jobs: scope through current_user.jobs.
  # - Epics: scope through current_user.epics.
  # - Workflows and Runs: join through job.repository and require the repository
  #   to belong to current_user.
  module AuthorizationSupport
    class AuthorizationError < StandardError; end

    module ToolDispatch
      def call(*args, server_context: nil, **kwargs, &block)
        SyrusChatMcp::AuthorizationSupport.with_server_context(server_context) do
          super(*args, server_context: server_context, **kwargs, &block)
        end
      rescue SyrusChatMcp::AuthorizationSupport::AuthorizationError
        SyrusChatMcp.not_authorized
      end
    end

    class << self
      def current_server_context
        Thread.current[:syrus_chat_mcp_authorization_server_context]
      end

      def with_server_context(server_context)
        previous = current_server_context
        Thread.current[:syrus_chat_mcp_authorization_server_context] = server_context
        yield
      ensure
        Thread.current[:syrus_chat_mcp_authorization_server_context] = previous
      end
    end

    def admin? = current_user.admin?

    def current_user = chat_session.user

    def chat_session = server_context.fetch(:chat_session)

    def server_context
      SyrusChatMcp::AuthorizationSupport.current_server_context || raise(KeyError, "server_context is required")
    end

    def find_job!(id, includes: nil)
      scope = admin? ? Job.all : current_user.jobs
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
      scope = scope.includes(includes) if includes
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "workflow not found or not accessible"
    end

    def find_run!(id)
      scope = admin? ? Run.all : Run.joins(step: { workflow: { job: :repository } }).where(repositories: { user_id: current_user.id })
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "run not found or not accessible"
    end

    def authorize_resource!(resource, action: :read)
      return resource if admin?

      owner = resource.try(:user) || resource.try(:repository)&.user
      raise AuthorizationError, "not authorized" unless owner == current_user

      resource
    end
  end
end
