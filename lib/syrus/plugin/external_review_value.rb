# frozen_string_literal: true

module Syrus
  module Plugin
    module ExternalReviewValue
      module_function

      def immutable(value)
        case value
        when Array
          value.map { |item| immutable(item) }.freeze
        when Hash
          value.to_h { |key, item| [ immutable(key), immutable(item) ] }.freeze
        else
          value.frozen? ? value : value.dup.freeze
        end
      rescue TypeError
        value.freeze
      end

      def public_facade!(name, value)
        raise ArgumentError, "#{name} is required" if value.nil?
        if defined?(ActiveRecord::Base) && value.is_a?(ActiveRecord::Base)
          raise ArgumentError, "#{name} must be a public facade, not an Active Record model"
        end
        if defined?(GithubClient) && value.is_a?(GithubClient)
          raise ArgumentError, "#{name} must be a public client facade, not GithubClient"
        end
        if %i[connected_account client].include?(name) && value.is_a?(String)
          raise ArgumentError, "#{name} must be a facade, not a raw credential"
        end

        value
      end
    end

    ExternalReviewArtifact = Data.define(:kind, :name, :content_type, :location, :metadata) do
      def initialize(kind:, name:, content_type:, location:, metadata: {})
        raise ArgumentError, "artifact kind is required" if kind.to_s.empty?
        raise ArgumentError, "artifact name is required" if name.to_s.empty?

        super(kind: kind.to_sym, name: name.to_s.freeze, content_type: content_type&.to_s&.freeze,
          location: ExternalReviewValue.immutable(location), metadata: ExternalReviewValue.immutable(metadata))
      end
    end

    ExternalReviewContext = Data.define(
      :repository, :job, :pull_request, :base_sha, :head_sha, :diff_review_version,
      :trigger, :rule, :links, :summary, :evidence, :connected_account, :client,
      :external_id, :idempotency_key
    ) do
      SHA_PATTERN = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i

      def initialize(repository:, job:, pull_request:, base_sha:, head_sha:, diff_review_version:,
        trigger:, rule:, links:, summary:, evidence:, connected_account:, client:,
        external_id: nil, idempotency_key: nil)
        %i[repository job pull_request connected_account client].each do |name|
          ExternalReviewValue.public_facade!(name, binding.local_variable_get(name))
        end
        raise ArgumentError, "base_sha must be an exact Git object id" unless base_sha.to_s.match?(SHA_PATTERN)
        raise ArgumentError, "head_sha must be an exact Git object id" unless head_sha.to_s.match?(SHA_PATTERN)

        super(repository:, job:, pull_request:, base_sha: base_sha.to_s.freeze, head_sha: head_sha.to_s.freeze,
          diff_review_version: ExternalReviewValue.immutable(diff_review_version),
          trigger: ExternalReviewValue.immutable(trigger), rule: ExternalReviewValue.immutable(rule),
          links: ExternalReviewValue.immutable(links), summary: ExternalReviewValue.immutable(summary),
          evidence: ExternalReviewValue.immutable(evidence), connected_account:, client:,
          external_id: external_id&.to_s&.freeze, idempotency_key: idempotency_key&.to_s&.freeze)
      end
    end

    ExternalReviewResult = Data.define(
      :outcome, :external_id, :idempotency_key, :retry_after, :artifacts, :feedback,
      :verdict, :publication, :metadata
    ) do
      OUTCOMES = %i[accepted completed declined retryable_failure terminal_failure].freeze
      PUBLICATIONS = %i[core provider none].freeze

      def initialize(outcome:, external_id: nil, idempotency_key: nil, retry_after: nil, artifacts: [],
        feedback: nil, verdict: nil, publication: :core, metadata: {})
        outcome = outcome.to_sym
        publication = publication.to_sym
        raise ArgumentError, "unknown external review outcome: #{outcome.inspect}" unless OUTCOMES.include?(outcome)
        raise ArgumentError, "unknown publication disposition: #{publication.inspect}" unless PUBLICATIONS.include?(publication)
        unless Array(artifacts).all? { |artifact| artifact.is_a?(ExternalReviewArtifact) }
          raise ArgumentError, "artifacts must contain ExternalReviewArtifact values"
        end

        super(outcome:, external_id: external_id&.to_s&.freeze, idempotency_key: idempotency_key&.to_s&.freeze,
          retry_after: ExternalReviewValue.immutable(retry_after), artifacts: Array(artifacts).dup.freeze,
          feedback: ExternalReviewValue.immutable(feedback), verdict: ExternalReviewValue.immutable(verdict),
          publication:, metadata: ExternalReviewValue.immutable(metadata))
      end

      OUTCOMES.each do |named_outcome|
        define_singleton_method(named_outcome) { |**attributes| new(outcome: named_outcome, **attributes) }
      end

      def retryable? = outcome == :retryable_failure
      def terminal? = %i[completed declined terminal_failure].include?(outcome)
    end
  end
end
