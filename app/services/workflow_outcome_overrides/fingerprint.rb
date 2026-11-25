require "digest"

module WorkflowOutcomeOverrides
  class Fingerprint
    ATTRIBUTES = %i[
      job_id workflow_id step_id gate_kind gate_identity candidate_head_sha
      candidate_tree_sha candidate_base_sha plan_version prompt_version evidence_digest
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(**attributes)
      attributes = attributes.symbolize_keys
      unknown = attributes.keys - ATTRIBUTES
      raise ArgumentError, "unknown fingerprint attributes: #{unknown.join(', ')}" if unknown.any?

      ATTRIBUTES.each { |attribute| instance_variable_set("@#{attribute}", attributes[attribute]) }
    end

    def to_h = ATTRIBUTES.index_with { |attribute| public_send(attribute) }

    def digest
      Digest::SHA256.hexdigest(JSON.generate(to_h.transform_keys(&:to_s).sort.to_h))
    end

    def self.from(record)
      new(**ATTRIBUTES.index_with { |attribute| record.public_send(attribute) })
    end
  end
end
