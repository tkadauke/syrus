module Mcp::Tools
  # Resource scoping convention for chat MCP tools:
  # - Jobs: scope through Job.visible_to(current_user), further restricted by context.allowed_job_ids when set.
  # - Epics: scope through Epic.accessible_to(current_user).
  # - Workflows and Runs: join through jobs visible to current_user; further restricted
  #   by allowed_workflow_ids / allowed_run_ids.
  # - ChatSessions: scoped through current_user.accessible_chat_sessions, further
  #   restricted by allowed_chat_session_ids. Admin only changes whether a
  #   soft-deleted session the caller participates in is included.
  #
  # allowed_*_ids are nil by default (no additional restriction beyond the
  # resource's base authorization scope).
  # They are populated by the McpToolContext when the surface restricts resource access —
  # for example, the future AGENT_INSIGHT role limits reads to a declared set of jobs.
  module AuthorizationSupport
    class AuthorizationError < StandardError; end

    module ToolDispatch
      def call(*args, server_context: nil, **kwargs, &block)
        Mcp::Tools::AuthorizationSupport.with_server_context(server_context) do
          scheduled = Mcp::Tools::AuthorizationSupport.pending_scheduled_authorization(self, server_context, kwargs)
          return scheduled if scheduled
          pending = Mcp::Tools::AuthorizationSupport.pending_coworker_approval(self, server_context, kwargs)
          return pending if pending

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

      def pending_coworker_approval(tool, server_context, arguments)
        context = McpToolContext.from_server_context(server_context)
        return unless context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])

        descriptor = Mcp::CoworkerToolCatalog.resolve(tool, chat_session: context.chat_session)
        raise AuthorizationError, "tool is not available to coworkers" unless descriptor
        return if descriptor.ungated
        return if claimed_invocation_authorizes?(descriptor, context, server_context, arguments)

        protected_path = protected_coworker_workspace_path?(context, descriptor, arguments)
        create_coworker_pending_action(context:, server_context:, descriptor:,
          arguments:, always_pending: protected_path)
      end

      def protected_coworker_workspace_path?(context, descriptor, arguments)
        return false unless descriptor.capability == "workspace.files"

        grant = context.agent_actor&.grants&.find_by(capability: "workspace.files")
        protected_paths = Array(grant&.constraints&.fetch("confirm_paths", nil)).filter_map do |path|
          normalized_coworker_workspace_path(path)
        end
        requested_paths = [ arguments[:path], arguments[:source], arguments[:destination] ].compact.filter_map do |path|
          normalized_coworker_workspace_path(path)
        end
        (protected_paths & requested_paths).any?
      end

      def normalized_coworker_workspace_path(path)
        candidate = Pathname.new(path.to_s)
        return if candidate.absolute?

        clean = candidate.cleanpath
        return if clean.to_s == ".." || clean.each_filename.first.in?([ "..", ".git" ])

        clean.to_s
      rescue ArgumentError
        nil
      end

      def pending_coworker_plugin_approval(tool_name, capability, server_context, arguments, always_pending: false)
        context = McpToolContext.from_server_context(server_context)
        return unless context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])

        descriptor = Mcp::CoworkerToolCatalog.resolve(tool_name, chat_session: context.chat_session)
        raise AuthorizationError, "tool is not available to coworkers" unless descriptor&.capability.to_s == capability.to_s
        return if claimed_invocation_authorizes?(descriptor, context, server_context, arguments)

        create_coworker_pending_action(context:, server_context:, descriptor:, arguments:, always_pending:)
      end

      def create_coworker_pending_action(context:, server_context:, descriptor:, arguments:, always_pending: false)
        capability_descriptor = if descriptor.tool
          McpToolRegistry.entries(surface: :coworker).find { |entry| entry.tool == descriptor.tool }&.descriptor
        else
          Permissions::CapabilityDescriptorAdapter.for_plugin_definition(descriptor.definition)
        end
        raise AuthorizationError, "tool has no permission descriptor" unless capability_descriptor

        result = Permissions::CoworkerAuthorizationRequest.new(
          context:, descriptor: capability_descriptor, arguments:,
          purpose: "Invoke #{descriptor.tool_name}",
          force_request: always_pending,
          action: "coworker_tool_call",
          payload: {
            "tool_name" => descriptor.tool_name,
            "arguments" => arguments.stringify_keys,
            "run_id" => context.run&.id,
            "origin_message_id" => server_context[:current_message]&.id,
            "approval_policy" => "queue",
            "approval_inbox" => true,
            "actor" => approval_actor(context.agent_actor)
          }.compact
        ).call
        return unless result.request

        action = result.request
        server_context[:current_message]&.update_columns(pending_action_id: action.id)
        Mcp::Tools.success(
          pending_confirmation_id: action.id,
          pending_action_id: action.id,
          approval_policy: "queue",
          message: I18n.t("server.permissions.coworker_request_waiting")
        )
      end

      def pending_scheduled_authorization(tool, server_context, arguments)
        context = McpToolContext.from_server_context(server_context)
        result = Permissions::ScheduledAuthorization.route(tool:, context:, arguments:)
        return unless result

        Mcp::Tools.success(
          authorization_request_id: result.request&.id,
          authorization_status: result.status,
          gated_operation_skipped: !result.created?,
          message: I18n.t("server.permissions.scheduled_authorization.#{result.created? ? 'waiting' : 'skipped'}")
        )
      end

      def approval_actor(actor)
        return unless actor

        {
          "name" => actor.respond_to?(:name) ? actor.name : nil,
          "handle" => actor.respond_to?(:handle) ? actor.handle : nil,
          "avatar_url" => actor.respond_to?(:avatar_url) ? actor.avatar_url : nil,
          "avatar_key" => actor.respond_to?(:avatar_key) ? actor.avatar_key : nil,
          "accent_hex" => actor.respond_to?(:accent_hex) ? actor.accent_hex : nil
        }.compact
      end

      def claimed_invocation_authorizes?(descriptor, context, server_context, arguments)
        invocation_id = server_context[:authorized_invocation_id]
        return false if invocation_id.blank?

        invocation = AuthorizedInvocation.find_by(id: invocation_id)
        raise AuthorizationError, "authorized invocation is unavailable" unless invocation&.claimed?
        raise AuthorizationError, "authorized invocation claim does not match" unless
          invocation.claim_key == server_context[:authorized_invocation_claim_key] &&
          invocation.claimed_by == context.agent_actor && invocation.tool_name == descriptor.tool_name

        capability_descriptor = if descriptor.tool
          McpToolRegistry.entries(surface: :coworker).find { |entry| entry.tool == descriptor.tool }&.descriptor
        else
          Permissions::CapabilityDescriptorAdapter.for_plugin_definition(descriptor.definition)
        end
        fingerprint = Permissions::InvocationFingerprint.call(descriptor: capability_descriptor, arguments:)
        ActiveSupport::SecurityUtils.secure_compare(invocation.invocation_fingerprint, fingerprint) ||
          raise(AuthorizationError, "authorized invocation fingerprint does not match")
      end

      def with_coworker_approval_bypass
        previous = Thread.current[:coworker_tool_approval_bypass]
        Thread.current[:coworker_tool_approval_bypass] = true
        yield
      ensure
        Thread.current[:coworker_tool_approval_bypass] = previous
      end
    end

    def admin?
      current_user.admin? && !mcp_context&.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
    end

    def current_user = mcp_context&.user || chat_session.user

    def chat_session = server_context.fetch(:chat_session)

    def server_context
      Mcp::Tools::AuthorizationSupport.current_server_context || raise(KeyError, "server_context is required")
    end

    def find_job!(id, includes: nil)
      scope = admin? ? Job.visible_to(current_user, scope: Job.all) : Job.visible_to(current_user)
      scope = scope.where(id: mcp_context.allowed_job_ids) if mcp_context&.allowed_job_ids
      scope = scope.includes(includes) if includes
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "job not found or not accessible"
    end

    def find_epic!(id, includes: nil)
      scope = admin? ? Epic.all : Epic.accessible_to(current_user)
      scope = scope.includes(includes) if includes
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "epic not found or not accessible"
    end

    def find_workflow!(id, includes: nil)
      scope = admin? ? Workflow.all : Workflow.joins(:job).where(jobs: { id: Job.visible_to(current_user).select(:id) })
      scope = scope.where(id: mcp_context.allowed_workflow_ids) if mcp_context&.allowed_workflow_ids
      scope = scope.includes(includes) if includes
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "workflow not found or not accessible"
    end

    def find_run!(id)
      scope = admin? ? Run.all : Run.joins(step: { workflow: :job }).where(jobs: { id: Job.visible_to(current_user).select(:id) })
      scope = scope.where(id: mcp_context.allowed_run_ids) if mcp_context&.allowed_run_ids
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "run not found or not accessible"
    end

    def find_chat_session!(id)
      scope = accessible_chat_sessions_scope
      scope.find_by!(id: id)
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "chat session not found or not accessible"
    end

    def accessible_chat_sessions_scope
      scope = current_user.accessible_chat_sessions
      scope = scope.active unless admin?
      scope = scope.where(id: mcp_context.allowed_chat_session_ids) if mcp_context&.allowed_chat_session_ids
      scope
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
