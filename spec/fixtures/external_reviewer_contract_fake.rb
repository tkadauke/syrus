# frozen_string_literal: true

# Test-only proof provider for the public external-reviewer contract. It has no
# persistence and selects deterministic responses from immutable rule input.
module ExternalReviewerContractFake
  class Service
    extend Syrus::Plugin::ExternalReviewer

    class << self
      def key = :contract_fake
      def provider_key = :contract_fake
      def display_name = "External reviewer contract fake"
      def external_reviewer(_context) = self
      def capabilities
        %i[artifact asynchronous_completion polling feedback verdict cancellation]
      end
      def available_for?(_context) = true

      def submit(context)
        case context.rule.fetch(:scenario)
        when :completed
          completed
        when :accepted
          Syrus::Plugin::ExternalReviewResult.accepted(
            external_id: "review-1", idempotency_key: "attempt-1", retry_after: 15
          )
        when :declined
          Syrus::Plugin::ExternalReviewResult.declined
        when :retryable_failure
          Syrus::Plugin::ExternalReviewResult.retryable_failure(retry_after: 30)
        when :terminal_failure
          Syrus::Plugin::ExternalReviewResult.terminal_failure(metadata: { code: "invalid_request" })
        when :malformed
          { outcome: :completed }
        when :raise
          raise "fake provider failure"
        when :slow
          sleep 0.02
          completed
        else
          raise ArgumentError, "unknown fake scenario"
        end
      end

      def refresh(context)
        return Syrus::Plugin::ExternalReviewResult.accepted(
          external_id: context.external_id, idempotency_key: context.idempotency_key, retry_after: 15
        ) if context.rule[:refresh] == :pending

        completed
      end

      def cancel(_context) = Syrus::Plugin::ExternalReviewResult.completed(metadata: { cancelled: true })

      private

      def completed
        artifact = Syrus::Plugin::ExternalReviewArtifact.new(
          kind: :report, name: "review.json", content_type: "application/json",
          location: { external_id: "artifact-1" }
        )
        Syrus::Plugin::ExternalReviewResult.completed(
          external_id: "review-1", artifacts: [ artifact ], feedback: [ { body: "Looks good" } ],
          verdict: :approved
        )
      end
    end
  end

  class NoCancellation
    extend Syrus::Plugin::ExternalReviewer

    class << self
      def provider_key = :no_cancellation
      def display_name = "No cancellation"
      def capabilities = %i[asynchronous_completion polling]
      def available_for?(_context) = true
      def submit(_context) = Syrus::Plugin::ExternalReviewResult.accepted(external_id: "review-2")
      def refresh(_context) = Syrus::Plugin::ExternalReviewResult.completed
    end
  end
end
