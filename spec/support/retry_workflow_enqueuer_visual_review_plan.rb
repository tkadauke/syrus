RSpec.configure do |config|
  config.before(:each, file_path: %r{/spec/services/retry_workflow_enqueuer_spec\.rb\z}) do
    stub_no_workflow_judges
  end
end
