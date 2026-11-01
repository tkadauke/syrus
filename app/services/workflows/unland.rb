module Workflows
  # Runs the repository's dedicated fast smoke gate against the proposed
  # revert tree. Revert construction and publication are owned by the unland
  # orchestration path; this workflow only prepares and grades that tree.
  class Unland < Base
    steps :prepare, :grader_fanout, :grader_collect

    def self.trigger_kind = "unland"

    def self.agentic? = false

    def self.queue_name = :merges
  end
end
