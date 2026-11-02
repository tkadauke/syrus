module Permissions
  class ApprovalProviderRequest
    attr_reader :owner, :capability, :operation, :resource_type, :resource_scope,
      :effects, :invocation_fingerprint, :transcript, :tool_call, :policy_chain, :repository_guidance

    def initialize(owner:, capability:, operation:, resource_type:, resource_scope:, effects:,
      invocation_fingerprint:, transcript:, tool_call:, policy_chain:, repository_guidance: nil)
      @owner = owner
      @capability = capability.to_s
      @operation = operation.to_s
      @resource_type = resource_type.to_s
      @resource_scope = resource_scope.to_h.deep_stringify_keys.freeze
      @effects = Array(effects).map(&:to_s).uniq.sort.freeze
      @invocation_fingerprint = invocation_fingerprint.to_s
      @transcript = Array(transcript).map { |entry| normalize_transcript_entry(entry) }.freeze
      @tool_call = tool_call.to_h.deep_stringify_keys.freeze
      @policy_chain = Array(policy_chain).map { |entry| entry.to_h.deep_stringify_keys.freeze }.freeze
      @repository_guidance = repository_guidance.to_s.freeze
      raise ArgumentError, "invocation_fingerprint is required" if @invocation_fingerprint.blank?
      freeze
    end

    private

    def normalize_transcript_entry(entry)
      normalized = entry.to_h.deep_stringify_keys
      raise ArgumentError, "transcript entries require a role" if normalized["role"].blank?
      raise ArgumentError, "transcript entries require content" unless normalized.key?("content")

      normalized.freeze
    end
  end
end
