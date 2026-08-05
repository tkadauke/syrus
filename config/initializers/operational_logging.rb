ActiveSupport::Notifications.subscribe("process_action.action_controller") do |_name, started, finished, _id, payload|
  OperationalLogging.ingest_request(payload, (finished - started) * 1_000.0)
end

ActiveSupport::Notifications.subscribe("perform.active_job") do |_name, started, finished, _id, payload|
  OperationalLogging.ingest_job(payload, (finished - started) * 1_000.0)
end
