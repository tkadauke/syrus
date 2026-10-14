module PendingActions
  class AdminMysqlKillQuery < Base
    action_key "admin_mysql_kill_query"

    def execute
      result = AdminMysql::Inspector.new.kill_query(
        payload.fetch("thread_id"),
        expected_statement: payload.fetch("statement")
      )
      raise ArgumentError, result.dig(:error, :message) unless result[:killed]

      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "thread_id is required") unless payload["thread_id"].present?
      errors.add(:payload, "statement is required") unless payload["statement"].present?
    end

    def action_detail
      "thread_id: #{payload["thread_id"]}\nstatement: #{payload["statement"]}"
    end

    def presentation_label
      "Kill MySQL query on thread #{payload["thread_id"]}"
    end

    def presentation_detail
      payload["statement"]
    end
  end
end
