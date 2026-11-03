module Permissions
  # The adaptive middle action of a coworker authorization card: the strongest
  # safe durable or time-bounded rule that the descriptor and every higher-layer
  # ceiling permit, derived from the canonical RuleDraft (never from a tool
  # name). Shared by the chat card and the approval inbox so both render the
  # same payload and apply it through the same code path.
  class SmartDecision
    SUPPORTED_ACTION = "coworker_tool_call".freeze
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
      user && request.authorization_request? && request.action == SUPPORTED_ACTION && request.user_id == user.id &&
        item.chat_pending_action_id == request.id && item.kind == "operation" && item.operation.present? &&
        request.pending? && request.actionable? && item.actionable? && item.prerequisites.all?(&:approved?)
    end

    # Payload shared by every surface; nil when only Allow once / Deny apply.
    def option
      return unless supported?

      duration = eligible.keys.first
      duration && payload_for(duration, eligible.fetch(duration))
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
        case duration
        when "job" then request.origin_type == "Job"
        when "chat_session" then request.chat_session_id.present?
        else true
        end
      end
    end

    def permitted?(duration, preview)
      duration != "permanent" || preview.draft.dig(:subject, :type) == "agent"
    end

    def draft_for(duration)
      RuleDraft.from_request_item(user:, request:, item:, duration:)
    end

    def payload_for(duration, preview)
      {
        kind: KINDS.fetch(duration), duration:, digest: preview.digest, summary: preview.summary,
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
  end
end
