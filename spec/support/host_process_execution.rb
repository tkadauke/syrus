# Raw host processes fail closed unless the canonical execution policy allows
# them (an `ask` cannot resume a spawned process). Specs that exercise real
# git/network subprocess behavior rather than the execution gate opt in with
# `:allow_host_execution` so the gate expresses "no opinion".
RSpec.configure do |config|
  config.before(:each, :allow_host_execution) do
    allow_any_instance_of(Permissions::ExecutionGate).to receive(:call).and_return(nil)
  end
end
