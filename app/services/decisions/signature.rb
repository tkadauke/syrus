require "digest"

module Decisions
  # A problem's identity for the purpose of "have we decided this before"
  # (workflow-engine-v3 B3).
  #
  # Problem code plus a normalized fingerprint of the evidence that identified
  # it. MainBranchFailureClassifier already computes this kind of fingerprint;
  # this states it once so every problem gets one.
  #
  # Normalization is the whole job. Two failures of the same grader on
  # different runs must fingerprint the same, or a decision never matches
  # anything twice and the queue stops compounding. So: only the keys declared
  # significant take part, values are stringified and sorted, and anything
  # run-specific (ids, timestamps, shas) is excluded by omission rather than by
  # a denylist that would silently admit the next new key.
  module Signature
    # Evidence keys that identify *which* problem this is, as opposed to which
    # occurrence of it. Anything not listed here is deliberately ignored.
    SIGNIFICANT_KEYS = %w[
      grader_name check_name step_kind command exit_status
      error_class provider tool_name branch_kind
    ].freeze

    DIGEST_LENGTH = 12

    def self.for(problem, extra: {})
      significant = normalize(problem.evidence.merge(extra))
      return problem.code if significant.empty?

      "#{problem.code}:#{digest(significant)}"
    end

    def self.normalize(evidence)
      evidence.to_h.stringify_keys.slice(*SIGNIFICANT_KEYS).transform_values(&:to_s).sort.to_h
    end

    def self.digest(significant)
      Digest::SHA256.hexdigest(significant.map { |key, value| "#{key}=#{value}" }.join("\n"))[0, DIGEST_LENGTH]
    end
  end
end
