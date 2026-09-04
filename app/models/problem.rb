# One failure, in the shared vocabulary (workflow-engine-v3 primitive A).
#
# A code from Problem::Kind plus the structured evidence that identified it.
# The code is what every control plane agrees on; the evidence is what a human
# or an adjudicator needs to decide whether the code was right.
#
#   Problem[:branch_diverged, evidence: { expected_sha:, observed_sha: })
#
# A1 introduces the vocabulary and the value; it does not change how any plane
# currently remediates. The existing classifiers keep writing the strings they
# always wrote -- those strings are now declared as aliases of a code here, so
# the translations are checkable.
class Problem
  attr_reader :evidence

  def self.[](code, evidence: {})
    new(code, evidence: evidence)
  end

  # Builds from whatever name a plane happens to use -- a run classification,
  # a Step `failure_code`, or a reconciler issue kind. Returns nil for a name
  # no plane has declared, so callers can fall back instead of raising.
  def self.resolve(name, evidence: {})
    entry = Kind.resolve(name)
    return nil unless entry

    new(entry.code, evidence: evidence)
  end

  def initialize(code, evidence: {})
    @entry = Kind.fetch(code)
    @evidence = evidence.to_h.freeze
    freeze
  end

  def code = @entry.code
  def scope = @entry.scope
  def retryable? = @entry.retryable
  def default_remediation = @entry.default_remediation
  def label = @entry.label

  def to_s = code
  def ==(other) = other.is_a?(Problem) && other.code == code && other.evidence == evidence
  alias eql? ==
  def hash = [ code, evidence ].hash

  def inspect = "#<Problem #{code}#{evidence.any? ? " #{evidence.inspect}" : ""}>"
end
