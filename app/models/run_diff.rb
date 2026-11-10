# Side table for the two diff texts a Run can carry. They used to be MEDIUMTEXT
# columns on `runs`, which made every whole-row `SELECT runs.*` plus an
# unindexed ORDER BY able to blow MySQL's sort buffer. One row per Run that has
# a diff; Runs without a diff have no row. Reached through Run#agent_diff and
# Run#step_agent_diff.
class RunDiff < ApplicationRecord
  belongs_to :run

  validates :run_id, uniqueness: true, allow_nil: true

  # SQL fragments, as correlated subqueries against the outer `runs` row, for
  # call sites that report diff sizes without loading the text. A Run with no
  # run_diffs row yields NULL here; callers coalesce to 0.
  def self.byte_length_sql(column, runs_table: "runs")
    column = column.to_s
    raise ArgumentError, "unknown diff column #{column}" unless %w[agent_diff step_agent_diff].include?(column)

    "(SELECT LENGTH(run_diffs.#{column}) FROM run_diffs WHERE run_diffs.run_id = #{runs_table}.id)"
  end

  def self.step_diff_matches_diff_sql(runs_table: "runs")
    "COALESCE((SELECT (run_diffs.step_agent_diff = run_diffs.agent_diff) " \
      "FROM run_diffs WHERE run_diffs.run_id = #{runs_table}.id), 0)"
  end

  # Preferred output diff for a Run (step diff, else full diff), empty strings
  # treated as absent.
  def self.preferred_diff_sql(runs_table: "runs")
    "(SELECT COALESCE(NULLIF(run_diffs.step_agent_diff, ''), NULLIF(run_diffs.agent_diff, '')) " \
      "FROM run_diffs WHERE run_diffs.run_id = #{runs_table}.id)"
  end
end
