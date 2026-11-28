require "rails_helper"

RSpec.describe Job::ClosureReason do
  it "describes every built-in reason through registry metadata" do
    expect(described_class.fetch("implemented_elsewhere")).to have_attributes(
      category: "delivered", success: true, requires_reference: true
    )
    expect(described_class.fetch("wont_do")).to have_attributes(
      category: "declined", requires_note: true, agent_allowed: false
    )
    expect(described_class.by_reason).not_to have_key("pr_approved")
  end

  it "validates required references and notes when closing" do
    job = Factories.job(state: "implemented")

    expect { job.close_with_reason!("duplicate") }.to raise_error(ArgumentError, /requires a Job/)
    expect { job.close_with_reason!("wont_do") }.to raise_error(ArgumentError, /requires a note/)
  end

  it "keeps closure history while clearing current details on reopen" do
    job = Factories.job(state: "implemented")
    StateTransition.with_source("operator", user: job.user) do
      job.close_with_reason!("implemented_elsewhere", references: [ { type: "PR", id: 12 } ])
    end

    expect { job.reopen! }.to change { job.reload.closure_reason }.to(nil)
    expect(job.closure_references).to be_nil
    expect(StateTransition.where(subject: job, to_state: "closed")).to exist
  end

  it "groups filter options by registry category" do
    options = Filters::Chips::Jobs::ClosureReason.values

    expect(options.find { |option| option["value"] == "pr_merged" }).to include("group" => "Delivered")
    expect(options.find { |option| option["value"] == "duplicate" }).to include("group" => "Replaced")
  end
end
