# Shared guard for MySQL's "Out of sort memory" hazard (error 1038).
#
# Code under test must never ask the database to sort whole rows of a wide
# table across an id list. Steps carry a JSON details column that grader steps
# fill with command output, Workflows a 16MB artifacts column, and Runs wide
# prompt/summary text; when the ORDER BY is not served by an index MySQL has to
# fit those rows in its sort buffer and fails. Preloading a Workflow's steps
# across an IN list of workflow ids did exactly that in production.
#
# Ordering a single workflow's steps is fine: workflow_id equality plus the
# (workflow_id, position) index is served without a sort. The multi-id IN list
# is what cannot be.
module HeavySortStatements
  # Returns the SQL statements issued inside the block that select whole rows
  # from a wide table, with an ORDER BY and a multi-id IN list. `tables`
  # narrows which wide tables count.
  def heavy_sort_statements(tables: %w[steps workflows runs])
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end
    begin
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # Whole-row select from a wide table, plus a sort, plus a multi-id IN
    # list. All three together are the hazard: a narrow correlated subquery
    # that orders by an indexed column to pick one id is not.
    statements.select do |sql|
      sql.match?(/select[^;]*[`"]?(#{tables.map { |t| Regexp.escape(t) }.join('|')})[`"]?\.\*/i) &&
        sql.match?(/\border by\b/i) &&
        sql.match?(/\bin\s*\(/i)
    end
  end
end
