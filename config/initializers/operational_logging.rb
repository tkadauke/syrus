ActiveSupport::Notifications.subscribe("process_action.action_controller") do |_name, started, finished, _id, payload|
  duration_ms = (finished - started) * 1_000.0
  BackendExceptionLogging.ingest_request(payload, duration_ms)
  OperationalLogging.ingest_request(payload, duration_ms)
end

ActiveSupport::Notifications.subscribe("perform.active_job") do |_name, started, finished, _id, payload|
  duration_ms = (finished - started) * 1_000.0
  BackendExceptionLogging.ingest_job(payload, duration_ms)
  OperationalLogging.ingest_job(payload, duration_ms)
end
