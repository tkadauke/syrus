# Observability::EventSink buffers non-durable-flush events (e.g. workflow
# activity from Run/Workflow state transitions) in process-level memory so
# tests never trigger the background flusher. That buffer is not scoped to
# an example or wrapped by transactional fixtures, so events recorded by
# earlier specs (any spec that creates a Job/Workflow/Run) leak into later
# specs that query recent activity, making event ordering depend on run
# order. Reset before every example to keep each spec's view of recent
# activity independent of what ran before it.
RSpec.configure do |config|
  config.before do
    Observability::EventSink.clear!
  end
end
