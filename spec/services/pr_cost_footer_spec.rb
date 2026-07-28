require "rails_helper"

RSpec.describe PrCostFooter do
  let(:repository) { Factories.repository }
  let(:job) { Factories.job(repository: repository, issue_number: 42) }

  def create_run(cost:)
    workflow = job.workflows.first
    step = workflow.steps.first
    step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      cost_usd: cost
    )
  end

  it "formats the managed PR footer with run count and total cost" do
    job.initial_run.update!(cost_usd: 0.123)
    create_run(cost: 0.456)

    body = described_class.apply("Body", job)

    expect(body).to include("This PR was implemented by Syrus across 2 Runs at a total cost of $0.58.")
    expect(body).to include(described_class::START_MARKER)
    expect(body).to include(described_class::END_MARKER)
  end

  it "replaces an existing managed footer instead of appending another one" do
    job.initial_run.update!(cost_usd: 0.10)
    first = described_class.apply("Body", job)
    create_run(cost: 0.20)

    body = described_class.apply(first, job)

    expect(body.scan("This PR was implemented by Syrus").size).to eq(1)
    expect(body).to include("across 2 Runs at a total cost of $0.30")
  end

  it "strips the managed footer when the repository opts out" do
    job.initial_run.update!(cost_usd: 0.10)
    existing = described_class.apply("Body", job)
    repository.update!(pr_cost_footer_enabled: false)

    body = described_class.apply(existing, job)

    expect(body).to eq("Body")
    expect(body).not_to include("total cost")
  end

  context "with SYRUS_APP_HOST configured" do
    around do |ex|
      old = ENV["SYRUS_APP_HOST"]
      ENV["SYRUS_APP_HOST"] = "https://syrus.example.com"
      ex.run
    ensure
      old ? (ENV["SYRUS_APP_HOST"] = old) : ENV.delete("SYRUS_APP_HOST")
    end

    it "appends a JOB backlink for epicless jobs" do
      body = described_class.apply("Body", job)

      expect(body).to include("[JOB-#{job.id}](https://syrus.example.com/jobs/#{job.id})")
      expect(body).not_to include("EPIC-")
    end

    it "appends EPIC and JOB backlinks when the job belongs to an epic" do
      epic = Factories.epic(repository: repository)
      job.update!(epic: epic)

      body = described_class.apply("Body", job)

      expect(body).to include("[EPIC-#{epic.number}](https://syrus.example.com/epics/#{epic.number})")
      expect(body).to include("[JOB-#{job.id}](https://syrus.example.com/jobs/#{job.id})")
      expect(body).to include(
        "[EPIC-#{epic.number}](https://syrus.example.com/epics/#{epic.number})" \
        " / " \
        "[JOB-#{job.id}](https://syrus.example.com/jobs/#{job.id})"
      )
    end

    it "strips a trailing slash from the host when building backlinks" do
      ENV["SYRUS_APP_HOST"] = "https://syrus.example.com/"

      body = described_class.apply("Body", job)

      expect(body).to include("[JOB-#{job.id}](https://syrus.example.com/jobs/#{job.id})")
      expect(body).not_to include("//jobs/")
    end
  end

  context "with SYRUS_APP_HOST set to a bare hostname" do
    around do |ex|
      old = ENV["SYRUS_APP_HOST"]
      ENV["SYRUS_APP_HOST"] = "syrus.example.com"
      ex.run
    ensure
      old ? (ENV["SYRUS_APP_HOST"] = old) : ENV.delete("SYRUS_APP_HOST")
    end

    it "prepends https:// so backlinks are absolute URLs" do
      body = described_class.apply("Body", job)

      expect(body).to include("[JOB-#{job.id}](https://syrus.example.com/jobs/#{job.id})")
      expect(body).not_to include("(syrus.example.com/")
    end

    it "prepends https:// and strips a trailing slash from a bare hostname" do
      ENV["SYRUS_APP_HOST"] = "syrus.example.com/"

      body = described_class.apply("Body", job)

      expect(body).to include("[JOB-#{job.id}](https://syrus.example.com/jobs/#{job.id})")
      expect(body).not_to include("//jobs/")
    end
  end

  context "with SYRUS_APP_HOST set to an http:// URL" do
    around do |ex|
      old = ENV["SYRUS_APP_HOST"]
      ENV["SYRUS_APP_HOST"] = "http://syrus.example.com"
      ex.run
    ensure
      old ? (ENV["SYRUS_APP_HOST"] = old) : ENV.delete("SYRUS_APP_HOST")
    end

    it "leaves the existing http:// scheme untouched" do
      body = described_class.apply("Body", job)

      expect(body).to include("[JOB-#{job.id}](http://syrus.example.com/jobs/#{job.id})")
    end
  end

  context "without SYRUS_APP_HOST configured" do
    around do |ex|
      old = ENV.delete("SYRUS_APP_HOST")
      ex.run
    ensure
      ENV["SYRUS_APP_HOST"] = old if old
    end

    it "omits backlinks when host is not set" do
      body = described_class.apply("Body", job)

      expect(body).not_to include("JOB-")
      expect(body).not_to include("EPIC-")
    end
  end
end
