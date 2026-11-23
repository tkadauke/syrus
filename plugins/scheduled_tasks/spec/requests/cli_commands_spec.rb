require "rails_helper"

RSpec.describe "Scheduled Tasks CLI commands", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let!(:task) do
    ScheduledTasks::Task.create!(repository: repository, user: user, name: "Weekly tests", kind: "cron", cron_expression: "0 9 * * 1", pr_pileup_policy: "skip", prompt: "Write tests.")
  end

  before do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "scheduled_tasks", version: "1.0.0", cli_commands: [
      { path: %w[schedule show], summary: "Show a schedule", handler: "ScheduledTasks::Cli::Show", arguments: [ { name: "ID", required: true } ] },
      { path: %w[schedule run], summary: "Run a schedule", handler: "ScheduledTasks::Cli::Run", arguments: [ { name: "ID", required: true } ] }
    ])
    PluginRecord.find_by!(name: "scheduled_tasks").update!(enabled: true)
    sign_in_as(user)
  end

  after { Syrus::PluginRegistry.reset! }

  it "returns the former show text shape" do
    post "/api/v1/app/cli_commands/execute", params: { plugin: "scheduled_tasks", path: %w[schedule show], args: [ task.id.to_s ] }, as: :json

    expect(response.parsed_body.dig("result", "text")).to include("Schedule ##{task.id}: Weekly tests", "Repository: acme/widgets", "Prompt:\n  Write tests.", "Recent jobs:\n  none")
  end

  it "returns the created Job slug when firing" do
    job = Factories.job(repository: repository, issue_number: 91)
    result = instance_double(ScheduledTasks::Fire::Result, fired?: true, job: job)
    allow(ScheduledTasks::Fire).to receive(:new).with(task).and_return(instance_double(ScheduledTasks::Fire, call: result))

    post "/api/v1/app/cli_commands/execute", params: { plugin: "scheduled_tasks", path: %w[schedule run], args: [ task.id.to_s ] }, as: :json

    expect(response.parsed_body.dig("result", "text")).to eq("Created #{job.slug}")
  end
end
