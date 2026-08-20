# ProviderCircuitBreaker.call(provider, include_logs: false) memoizes its
# Decision per provider in a process-level cache for READ_CACHE_TTL (see
# app/services/provider_circuit_breaker.rb). Retry gates (RetryWorkflowEnqueuer,
# SmartRetryEnqueuer, AutoRetryJob, WorkEngine::RepairExecutor) all call through
# this cached path now, so a decision cached by an earlier example can leak into
# a later one that expects a fresh read. Reset before every example to keep
# circuit-breaker specs independent of run order.
RSpec.configure do |config|
  config.before do
    ProviderCircuitBreaker.clear_read_cache!
  end
end
