module Permissions
  class CoworkerAuthorizationDecision
    Result = Data.define(:request, :execution_enqueued)

    def initialize(request:, item:, user:)
      @request = request
      @item = item
      @user = user
    end

    def call(decision:)
      raise ArgumentError, "not a coworker authorization request" unless request.authorization_request? && request.action == "coworker_tool_call"
      raise ActiveRecord::RecordNotFound, "authorization request belongs to another user" unless request.user == user
      raise ArgumentError, "authorization item belongs to another request" unless item.chat_pending_action_id == request.id

      decision = decision.to_s
      raise ArgumentError, "decision must be approved or denied" unless decision.in?(%w[approved denied])

      ready = request.with_lock do
        return Result.new(request:, execution_enqueued: false) unless request.pending? && item.reload.actionable?

        if decision == "denied"
          item.decide!(decision, principal: user)
          request.authorization_items.pending.where.not(id: item.id).find_each do |pending|
            pending.mark_non_actionable!("Another authorization prerequisite was denied")
          end
          request.update!(state: "rejected", rejected_at: Time.current)
          return Result.new(request:, execution_enqueued: false)
        end

        authority = possession_authority
        duration = item.kind == "operation" ? "invocation" : nil
        item.decide!(decision, principal: user, duration:, resulting_authority: authority)
        request.reload.ready_for_authorized_invocation?
      end
      enqueued = ready && request.enqueue_confirmation!(user: user)
      Result.new(request:, execution_enqueued: enqueued)
    end

    private

    attr_reader :request, :item, :user

    def possession_authority
      return unless item.kind == "capability_possession"

      coworker = request.subject
      raise ArgumentError, "authorization subject is not a coworker" unless coworker.is_a?(Coworkers::Coworker)

      legacy_descriptor = Coworkers::GrantCatalog.fetch(item.capability)
      scope = legacy_descriptor.scopeable? ? item.resource_scope : nil
      coworker.grants.find_or_create_by!(capability: item.capability) do |grant|
        grant.approval_policy = "confirm"
        grant.scope = scope
      end
    end
  end
end
