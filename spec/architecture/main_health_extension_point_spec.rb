require "rails_helper"

RSpec.describe "main-health extension-point boundary" do
  it "keeps direct main-health policy calls inside its registered provider" do
    allowlist = %w[
      app/controllers/api/v1/app/repositories_controller.rb
      app/jobs/poll_pull_request_job.rb
      app/models/repository.rb
      app/services/adjudicators/reported_main_concern.rb
      app/services/app/dashboard_payload/chrome_serializers.rb
      app/services/main_branch_health_provider.rb
      app/services/main_health_changed_service.rb
      app/services/main_concern_aggregator.rb
      app/services/metrics/resilience_source.rb
      app/services/repositories/plugin_repo_tabs_payload.rb
      app/services/step_dispatcher.rb
      app/services/work_engine/reconciler.rb
      app/services/work_units/gates/main_branch_health.rb
      app/services/work_units/start_block.rb
      app/jobs/poll_main_branch_health_job.rb
      app/services/workflows/main_branch_repair.rb
      app/services/workflows/main_grader.rb
    ]
    offenders = Dir[Rails.root.join("app/**/*.rb")].filter_map do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      next if allowlist.include?(relative)

      relative if File.read(path).match?(/\b(?:main_health_broken\?|main_health_blocking\?)/)
    end

    expect(offenders).to eq([]), <<~MESSAGE
      Core must consult WorkGates instead of main-health policy directly.
      The short allowlist contains the provider and health lifecycle code that
      will move with the main-health plugin.
    MESSAGE
  end
end
