# Shared detector for the production hazard where a whole-row select from a
# wide table is combined with an unindexable ORDER BY across an IN list.
module HeavySortStatements
  def heavy_sort_statements
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
      sql.match?(/select[^;]*[`"]?(steps|workflows|runs)[`"]?\.\*/i) &&
        sql.match?(/\border by\b/i) &&
        sql.match?(/\bin\s*\(/i)
    end
  end
end
