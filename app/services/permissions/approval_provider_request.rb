module Permissions
  class ApprovalProviderRequest
    REPOSITORY_GUIDANCE_UNSET = Object.new.freeze

    attr_reader :owner, :capability, :operation, :resource_type, :resource_scope,
      :effects, :invocation_fingerprint, :transcript, :tool_call, :policy_chain, :repository_guidance

    def initialize(owner:, capability:, operation:, resource_type:, resource_scope:, effects:,
      invocation_fingerprint:, transcript:, tool_call:, policy_chain:, repository: nil,
      repository_guidance: REPOSITORY_GUIDANCE_UNSET)
      @owner = owner
      @capability = capability.to_s
      @operation = operation.to_s
      @resource_type = resource_type.to_s
      @resource_scope = ImmutableValue.deep_freeze(resource_scope.to_h.deep_stringify_keys)
      @effects = Array(effects).map(&:to_s).uniq.sort.freeze
      @invocation_fingerprint = invocation_fingerprint.to_s
      @transcript = Array(transcript).map { |entry| normalize_transcript_entry(entry) }.freeze
      @tool_call = ImmutableValue.deep_freeze(tool_call.to_h.deep_stringify_keys)
      @policy_chain = ImmutableValue.deep_freeze(Array(policy_chain).map { |entry| entry.to_h.deep_stringify_keys })
      guidance = repository_guidance.equal?(REPOSITORY_GUIDANCE_UNSET) ? guidance_for(repository) : repository_guidance
      @repository_guidance = guidance.to_s.presence&.freeze
      raise ArgumentError, "invocation_fingerprint is required" if @invocation_fingerprint.blank?
      freeze
    end

    def to_h
      {
        "capability" => capability, "operation" => operation, "resource_type" => resource_type,
        "resource_scope" => resource_scope, "effects" => effects,
        "invocation_fingerprint" => invocation_fingerprint, "policy_chain" => policy_chain
      }
    end

    private

    def normalize_transcript_entry(entry)
      normalized = entry.to_h.deep_stringify_keys
      raise ArgumentError, "every transcript entry requires an explicit role" if normalized["role"].blank?

      ImmutableValue.deep_freeze(normalized)
    end

    def guidance_for(repository)
      return unless repository

      RepoDefaultBranchSyrusYml.new(repository:, user: owner).resolve.config&.ai_approval&.instructions
    end
  end
end
