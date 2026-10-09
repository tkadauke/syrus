require "rails_helper"

RSpec.describe "CLI job state filters" do
  it "only exposes real Job states or documented aliases" do
    source = Rails.root.join("cli/cmd/job_states.go").read
    body = source.match(/var jobStateFilters = \[\]string\{(?<body>.*?)\n\}/m)[:body]
    cli_states = body.scan(/"([^"]+)"/).flatten
    aliases = %w[all open]

    expect(cli_states - Job::STATES - aliases).to be_empty
    expect(cli_states).to include(*Job::STATES)
  end
end
