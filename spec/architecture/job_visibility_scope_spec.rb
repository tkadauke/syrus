require "rails_helper"

RSpec.describe "canonical Job visibility scope" do
  # These are the user-facing read boundaries that list, search, count, or
  # serialize Jobs. Adding a new boundary requires adding it here and routing
  # its base relation through Job.visible_to (directly or via policy_scope).
  BOUNDARIES = {
    "app/policies/job_policy.rb" => /\.visible_to\(user\)/,
    "app/controllers/api/v1/app/jobs_controller.rb" => /policy_scope\(Job\)/,
    "app/controllers/api/v1/app/repositories_controller.rb" => /Job\.visible_to\(Current\.user/,
    "app/services/app/dashboard_payload.rb" => /Job\.visible_to\(user/,
    "app/services/mcp/tools/list_jobs_tool.rb" => /Job\.visible_to\(context\.user/,
    "app/services/mcp/tools/search_jobs_tool.rb" => /Job\.visible_to\(context\.user/,
    "app/services/mcp/tools/authorization_support.rb" => /Job\.visible_to\(current_user/,
    "plugins/global_search/app/controllers/api/v1/app/search_controller.rb" => /Job\.visible_to\(/,
    "app/channels/job_channel.rb" => /Job\.visible_to\(current_user/
  }.freeze

  it "routes every registered user-facing Job read boundary through the canonical scope" do
    failures = BOUNDARIES.filter_map do |relative_path, canonical_scope|
      source = Rails.root.join(relative_path).read
      relative_path unless source.match?(canonical_scope)
    end

    expect(failures).to be_empty,
      "Job read boundaries bypassed Job.visible_to/policy_scope: #{failures.join(', ')}"
  end

  it "does not reintroduce the repository-only scope in registered read boundaries" do
    bypasses = BOUNDARIES.keys.filter_map do |relative_path|
      source = Rails.root.join(relative_path).read
      relative_path if source.match?(/Job\.accessible_to\(/) && relative_path != "app/policies/job_policy.rb"
    end

    expect(bypasses).to be_empty,
      "Use Job.visible_to for user-facing reads instead of Job.accessible_to: #{bypasses.join(', ')}"
  end
end
