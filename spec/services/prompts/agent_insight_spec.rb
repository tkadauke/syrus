require "rails_helper"

RSpec.describe Prompts::AgentInsight do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def prompt(**overrides)
    described_class.new(repository: repository, **overrides).to_s
  end

  it "identifies the target repository in the header" do
    expect(prompt).to include(repository.slug)
  end

  it "includes the submit_insight tool name in instructions" do
    expect(prompt).to include("submit_insight")
  end

  it "includes all required submit_insight fields" do
    output = prompt
    expect(output).to include("title")
    expect(output).to include("category")
    expect(output).to include("severity")
    expect(output).to include("confidence")
  end

  describe "suggestion type rules" do
    it "instructs the agent to set suggested_prompt for code defects requiring a fix" do
      output = prompt
      expect(output).to include("suggested_prompt")
      expect(output).to match(/code defect|code change/i)
    end

    it "instructs the agent to set memory_suggestion for durable behavioral patterns" do
      output = prompt
      expect(output).to include("memory_suggestion")
      expect(output).to match(/behavioral pattern|durable/i)
    end

    it "instructs the agent to file both when a fix is in flight and interim context is needed" do
      output = prompt
      expect(output).to match(/file both|both.*suggested_prompt.*memory_suggestion/im)
    end

    it "explicitly forbids memory_suggestion for a pure code bug with a clear fix" do
      output = prompt
      expect(output).to match(/do not file a memory suggestion.*code bug|purely.*code bug.*do not/im)
    end

    it "states that a memory for a bug-about-to-be-fixed misleads future agents" do
      output = prompt
      expect(output).to match(/misleads?\s+future agents/i)
    end
  end

  describe "recent jobs section" do
    it "is omitted when there are no recent jobs" do
      expect(prompt(recent_jobs: [])).not_to include("Recent Jobs")
    end

    it "lists each job with its id, kind, state, and title" do
      job = Factories.job(user: user, repository: repository)
      job.update!(issue_title: "Fix the thing")
      output = prompt(recent_jobs: [job])
      expect(output).to include("JOB-#{job.id}")
      expect(output).to include("Fix the thing")
    end
  end

  describe "memory context" do
    it "is omitted when the user has no repository-scoped memories" do
      output = prompt(user: user)
      # Prompts::MemoryContext returns blank when there are no memories,
      # so the section should not appear.
      expect(output).not_to include("## Memory")
    end
  end
end
