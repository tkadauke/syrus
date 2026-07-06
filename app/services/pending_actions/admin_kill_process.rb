module PendingActions
  class AdminKillProcess < Base
    action_key "admin_kill_process"

    def execute
      process = SpawnedProcess.find(payload.fetch("process_id"))
      process.request_kill!(user: user) if process.running?
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "process_id is required") unless payload["process_id"].present?
    end

    def action_detail
      "process_id: #{payload["process_id"]}"
    end
  end
end
