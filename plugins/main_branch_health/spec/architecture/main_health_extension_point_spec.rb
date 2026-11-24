require "rails_helper"

RSpec.describe "main-health extension-point boundary" do
  it "keeps direct main-health policy calls out of core except the generic work-gate consult sites" do
    allowlist = %w[
      app/jobs/poll_pull_request_job.rb
      app/models/repository.rb
      app/services/step_dispatcher.rb
      app/services/work_engine/reconciler.rb
      app/services/work_units/start_block.rb
    ]
    offenders = Dir[Rails.root.join("app/**/*.rb")].filter_map do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      next if allowlist.include?(relative)

      relative if File.read(path).match?(/\b(?:main_health_broken\?|main_health_blocking\?)/)
    end

    expect(offenders).to eq([]), "Core must consult WorkGates instead of main-health policy directly."
  end
end
