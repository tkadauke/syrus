module TestInsights
  # A single agent-run "I ran this exact failing example against this exact
  # failing SHA in isolation, and it did/did not reproduce" record
  # (EPIC-362). Backs Adjudicators::IsolatedReproDismissal.
  #
  # Deliberately its own table, not a TestCase row: TestCase.flakiness_score
  # reads TestCase.scored, the aggregate statistical history built from real
  # grader runs. An isolated repro attempt is a different kind of evidence --
  # one deliberate, single-example action with a verifiable command + output
  # trace, not a grader execution -- and mixing it into TestCase would dilute
  # that statistical pool. See TestCase#wip_repair_failures for the same
  # "keep self-repair signal out of the scored pool" principle applied to a
  # different confound.
  class IsolatedReproAttempt < ApplicationRecord
    self.table_name = "test_insight_isolated_repro_attempts"

    # Raw command/output can be large; keep the row bounded the same way
    # other captured-output columns are (RunTargetPrepareTool's
    # OUTPUT_TAIL_BYTES, GradeFailureFeedback's TAIL_BYTES).
    MAX_TEXT_BYTES = 16.kilobytes
    MAX_COMMAND_BYTES = 4.kilobytes

    # Evidence this narrow-purpose is only ever useful in the immediate
    # aftermath of the grading iteration it was recorded for -- once that
    # long gone, the record is dead weight, unlike TestCase's statistical
    # history which stays relevant for the full flakiness lookback window.
    RETAIN_AFTER = 30.days

    belongs_to :repository

    validates :grader_name, :suite_name, :name, :sha, presence: true
    validates :reproduced, inclusion: { in: [ true, false ] }

    scope :prunable, -> {
      where("created_at < ?", RETAIN_AFTER.ago)
    }

    scope :for_lookup, ->(repository:, suite_name:, name:, sha:) {
      where(repository_id: repository.is_a?(::Repository) ? repository.id : repository, suite_name: suite_name, name: name, sha: sha)
    }

    def self.truncate_command(value)
      value.nil? ? nil : value.to_s.safe_byteslice(0, MAX_COMMAND_BYTES)
    end

    def self.truncate_output(value)
      value.nil? ? nil : value.to_s.safe_byteslice(0, MAX_TEXT_BYTES)
    end
  end
end
