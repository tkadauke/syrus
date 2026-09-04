require "rails_helper"

RSpec.describe SourceRef do
  let(:repo) { Factories.repository(owner: "acme", name: "widgets") }

  # external_ref holds the bare issue number and is only unambiguous when also
  # scoped by input_source_id; "42" from two doors is two different things.
  it "qualifies a ref with the door it came through" do
    expect(described_class.build(kind: "github", qualifier: "acme/widgets#42"))
      .to eq("github:acme/widgets#42")
  end

  it "round-trips through parse" do
    expect(described_class.parse("github:acme/widgets#42"))
      .to eq(kind: "github", qualifier: "acme/widgets#42")
  end

  it "refuses to build a half-empty ref" do
    expect(described_class.build(kind: "github", qualifier: "")).to be_nil
    expect(described_class.build(kind: "", qualifier: "x")).to be_nil
  end

  it "returns nil for something that is not a ref" do
    expect(described_class.parse("github")).to be_nil
  end

  describe ".for_job" do
    it "identifies an issue-backed Job by repository and issue" do
      job = Factories.job(repository: repo, issue_number: 42)

      expect(described_class.for_job(job)).to eq("github:acme/widgets#42")
    end

    it "identifies a scheduled Job by its task" do
      job = Factories.job_record(repository: repo, kind: "cron", issue_number: nil, scheduled_task_id: 7)

      expect(described_class.for_job(job)).to eq("scheduled_task:7")
    end

    # A prompt someone typed is not the same request as anything else.
    it "gives a direct Job no external identity" do
      job = Factories.job_record(repository: repo, kind: "direct", issue_number: nil)

      expect(described_class.for_job(job)).to be_nil
    end
  end

  describe "Job#source_ref" do
    it "is derived on save and findable" do
      job = Factories.job(repository: repo, issue_number: 42)

      expect(job.reload.source_ref).to eq("github:acme/widgets#42")
      expect(Job.for_source_ref("github:acme/widgets#42")).to include(job)
    end

    it "follows the issue it names" do
      job = Factories.job(repository: repo, issue_number: 42)
      job.update!(issue_number: 43)

      expect(job.reload.source_ref).to eq("github:acme/widgets#43")
    end
  end
end
