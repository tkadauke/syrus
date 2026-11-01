module AuthorizationContinuations
  class Coordinator
    Result = Data.define(:status, :request, :continuation)

    def self.call(...) = new(...).call

    def initialize(request:, outcome:, tool_result: nil, denial_reason: nil)
      @request = request
      @outcome = outcome.to_s
      @tool_result = tool_result
      @denial_reason = denial_reason
    end

    def call
      raise ArgumentError, "outcome must be approved or denied" unless outcome.in?(%w[approved denied])

      continuation = nil
      status = nil
      adapter = nil
      request.with_lock do
        request.reload
        unless request.checkpoint_state.in?(%w[waiting resume_failed])
          return Result.new(status: :already_claimed, request:, continuation: nil)
        end

        adapter = Origin.for(request.origin)
        unless adapter&.resumable?
          request.mark_checkpoint_non_resumable!("origin_no_longer_resumable")
          return Result.new(status: :non_resumable, request:, continuation: nil)
        end

        request.begin_authorization_resume!
        continuation = payload
        adapter.deliver!(continuation)
        request.complete_authorization_resume! if adapter.complete_on_delivery?
        status = :delivered
      end

      adapter.dispatch!
      Result.new(status:, request:, continuation:)
    rescue StandardError => error
      request.reload
      request.begin_authorization_resume! if request.checkpoint_state.in?(%w[waiting resume_failed])
      request.fail_authorization_resume!(error) if request.checkpoint_state == "resuming"
      raise
    end

    private

    attr_reader :request, :outcome, :tool_result, :denial_reason

    def payload
      checkpoint = request.checkpoint_payload
      return Payload.approved(checkpoint:, tool_result:) if outcome == "approved"

      Payload.denied(checkpoint:, reason: denial_reason)
    end

  end
end
