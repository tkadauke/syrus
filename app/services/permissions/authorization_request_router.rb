module Permissions
  # One routing point for authorization attention. In particular, repeated
  # schedule fires attach to an existing request instead of opening another
  # checkpoint and may continue work that does not need the gated operation.
  class AuthorizationRequestRouter
    Result = Data.define(:request, :status) do
      def created? = status == :created
      def reused? = status == :reused
      def suppressed? = status.in?(%i[denial_cooldown request_cap])
      def checkpoint_required? = created?
      def continue_ungated? = !created?
    end

    DENIAL_COOLDOWN = 15.minutes
    MAX_ACTIVE_PER_SUBJECT_CAPABILITY = 3

    def self.route!(**attributes) = new(**attributes).route!

    def initialize(user:, repository:, origin:, subject:, runtime_role:, deduplication_key:, purpose:,
      occurrence_origin: origin,
      capability:, operation:, item_attributes:, occurrence_metadata: {}, now: Time.current)
      @request_attributes = {
        user:, repository:, origin:, subject:, runtime_role:, deduplication_key:, purpose:
      }
      @capability = capability.to_s
      @operation = operation.to_s
      @item_attributes = item_attributes
      @occurrence_metadata = occurrence_metadata
      @occurrence_origin = occurrence_origin
      @now = now
    end

    def route!
      subject.with_lock do
        if (request = recent_denied_request)
          associate!(request)
          return Result.new(request:, status: :denial_cooldown)
        end

        if (request = ChatPendingAction.find_equivalent(deduplication_key))
          associate!(request)
          return Result.new(request:, status: :reused)
        end

        return Result.new(request: nil, status: :request_cap) if active_request_count >= MAX_ACTIVE_PER_SUBJECT_CAPABILITY

        request = ChatPendingAction.create_or_find_authorization_request!(@request_attributes)
        if request.authorization_items.empty?
          request.authorization_items.create!(@item_attributes.merge(capability:, operation:))
        end
        associate!(request)
        Result.new(request:, status: request.origin == origin ? :created : :reused)
      end
    end

    private

    attr_reader :capability, :operation, :now

    def user = @request_attributes.fetch(:user)
    def subject = @request_attributes.fetch(:subject)
    def origin = @request_attributes.fetch(:origin)
    def deduplication_key = @request_attributes.fetch(:deduplication_key)

    def associate!(request)
      request.occurrences.create_or_find_by!(origin: @occurrence_origin) do |occurrence|
        occurrence.metadata = @occurrence_metadata
      end
    end

    def recent_denied_request
      ChatPendingAction
        .where(user:, subject:, request_kind: "authorization_request", deduplication_key:)
        .joins(:authorization_items)
        .where(pending_action_items: { capability:, operation:, state: "denied" })
        .where(pending_action_items: { decided_at: (now - DENIAL_COOLDOWN)..now })
        .order("pending_action_items.decided_at DESC")
        .first
    end

    def active_request_count
      ChatPendingAction.actionable
        .where(user:, subject:, request_kind: "authorization_request")
        .joins(:authorization_items)
        .where(pending_action_items: { capability: })
        .distinct
        .count
    end
  end
end
