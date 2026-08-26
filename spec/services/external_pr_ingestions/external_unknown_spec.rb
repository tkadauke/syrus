require "rails_helper"
require "ostruct"

RSpec.describe ExternalPrIngestions::ExternalUnknown do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme") }
  let(:pr) do
    OpenStruct.new(
      number: 10, title: "Add widget",
      user: OpenStruct.new(login: "contributor"),
      head: OpenStruct.new(ref: "feature/add-widget", repo: OpenStruct.new(full_name: "contributor/widgets")),
      base: OpenStruct.new(ref: "main", repo: OpenStruct.new(full_name: repository.slug))
    )
  end

  describe "#ingest!" do
    it "creates an ordinary external_pr Job and dispatches the grade-loop workflow" do
      job = nil
      expect {
        job = described_class.new.ingest!(repository: repository, pr: pr, fork_pr: true)
      }.to change(Job, :count).by(1).and change(Workflow, :count).by(1)

      expect(job.kind).to eq("external_pr")
      expect(job.external_pr_number).to eq(10)
      expect(job.external_pr_fork).to be(true)
      expect(job.epic_id).to be_nil
      expect(Workflow.last.trigger_kind).to eq("external_pr_ingest")
    end
  end
end
