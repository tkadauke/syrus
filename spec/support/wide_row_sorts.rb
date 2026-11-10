# Detects the query shape that raises MySQL's `Out of sort memory` (error
# 1038): a whole-row select from a table carrying large text/JSON columns,
# combined with a sort MySQL cannot serve from an index.
#
# The tables involved all have wide columns -- `runs.agent_diff` and
# `runs.step_agent_diff` (MEDIUMTEXT), `workflows.artifacts` (MEDIUMTEXT),
# `steps.details` (JSON, filled with grader command output). The usual way to
# emit one of these by accident is an `includes` of an ordered `has_many`
# across an `IN` list of parent ids, which no (parent_id, position) index can
# serve.
module WideRowSorts
  WIDE_TABLES = %w[steps workflows runs].freeze

  # Returns the offending statements emitted inside the block, newest first.
  # A narrow correlated subquery that orders by an indexed column to pick one
  # id is not a hazard and is deliberately not matched: the select has to pull
  # whole rows.
  def wide_row_sort_statements
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end
    begin
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    statements.select { |sql| wide_row_sort?(sql) }
  end

  def wide_row_sort?(sql)
    sql.match?(/select[^;]*[`"]?(#{WIDE_TABLES.join('|')})[`"]?\.\*/i) &&
      sql.match?(/\border by\b/i) &&
      sql.match?(/\bin\s*\(/i)
  end
end

RSpec.configure do |config|
  config.include WideRowSorts
end
