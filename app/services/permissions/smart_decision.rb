module Permissions
  # The adaptive middle action of a coworker authorization card: the strongest
  # safe durable or time-bounded rule that the descriptor and every higher-layer
  # ceiling permit, derived from the canonical RuleDraft (never from a tool
  # name). Shared by the chat card and the approval inbox so both render the
  # same payload and apply it through the same code path.
  class SmartDecision
    SUPPORTED_ACTIONS = %w[ authorized_tool_call coworker_tool_call coworker_permission_request ].freeze
    DURATION_RANK = { "chat_session" => 0, "job" => 1, "permanent" => 2 }.freeze
    # Strongest first. Permanent authority is only ever offered for the exact
    # coworker that asked; "similar" never widens to a role or chat type.
    CANDIDATES = %w[ permanent job chat_session ].freeze
    KINDS = { "permanent" => "always_allow_similar", "job" => "allow_job", "chat_session" => "allow_chat" }.freeze

    class AlreadyDecided < StandardError; end

    def self.authority_reference(item)
      authority = item.resulting_authority
      return unless authority

      { kind: authority.class.name, id: authority.id }
    end

    def initialize(request:, item:, user:)
      @request = request
      @item = item
      @user = user
    end

    def supported?
      user && request.authorization_request? && request.action.in?(SUPPORTED_ACTIONS) && request.user_id == user.id &&
        item.chat_pending_action_id == request.id && item.kind == "operation" && item.operation.present? &&
        request.pending? && request.actionable? && item.actionable? && item.prerequisites.all?(&:approved?)
    end

    # Payload shared by every surface; nil when only Allow once / Deny apply.
    def option
      return unless supported?

      duration = eligible.keys.first
      duration && payload_for(duration, eligible.fetch(duration))
    end

    # Every safe duration is presented explicitly. This matters for operations
    # such as SSH where chat-scoped and durable exact-command authority are
    # meaningfully different operator choices.
    def options
      return [] unless supported?

      return [ option ].compact unless item.operation.to_s.start_with?("ssh.execute/")

      %w[chat_session permanent].filter_map do |duration|
        preview = eligible[duration]
        payload_for(duration, preview) if preview
      end
    end

    # Returns the applied rule or lease. Must run inside the request lock so the
    # rule and the invocation approval commit or roll back together.
    def apply_rule!(duration:, digest:)
      raise AlreadyDecided, I18n.t("api.permission_requests.smart_decision.stale") unless supported?
      raise ArgumentError, I18n.t("api.permission_requests.smart_decision.unavailable") unless eligible.key?(duration.to_s)

      draft_for(duration.to_s).apply!(digest:, actor: user)
    end

    private

    attr_reader :request, :item, :user

    def eligible
      @eligible ||= candidate_durations.each_with_object({}) do |duration, found|
        preview = draft_for(duration).preview
        found[duration] = preview if preview.valid? && preview.warnings.empty? && permitted?(duration, preview)
      end
    end

    def candidate_durations
      CANDIDATES.select do |duration|
        next false unless item.requested_durations.include?(duration)
        next false if duration_above_request?(duration)

        case duration
        when "job" then request.origin_type == "Job"
        when "chat_session" then request.chat_session_id.present?
        else true
        end
      end
    end

    # A coworker names the narrowest duration it needs; the card never offers
    # more than that, whatever the descriptor would otherwise allow.
    def duration_above_request?(duration)
      return false unless request.action == CoworkerPermissionRequest::ACTION

      requested = request.payload.to_h["requested_duration"]
      DURATION_RANK.fetch(duration) > DURATION_RANK.fetch(requested, 0)
    end

    def permitted?(duration, preview)
      return true unless duration == "permanent" && request.action == CoworkerPermissionRequest::ACTION
      return true unless request.runtime_role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])

      preview.draft.dig(:subject, :type) == "agent"
    end

    def draft_for(duration)
      RuleDraft.from_request_item(user:, request:, item:, duration:)
    end

    def payload_for(duration, preview)
      {
        kind: kind_for(duration), duration:, digest: preview.digest, summary: preview.summary,
        draft: preview.draft, ceiling: preview.ceiling,
        context: {
          coworker: RequestPresenter.reference(request.subject)&.fetch(:label),
          operation: item.operation,
          repository: RequestPresenter.reference(request.repository)&.fetch(:label),
          resource_scope_label: preview.draft[:resource_scope_label],
          duration:
        }
      }
    end

    def kind_for(duration)
      return "always_allow_command" if duration == "permanent" && item.operation.to_s.start_with?("ssh.execute/")

      KINDS.fetch(duration)
    end
  end
end
