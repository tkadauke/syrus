require "rails_helper"
require "ostruct"

RSpec.describe ExternalPrIngestions::SyrusBranchExport do
  let(:user) { Factories.user }
  let(:canonical) { Factories.repository(user: user, owner: "acme") }
  let(:fork) { Factories.repository(user: user, owner: "bob", name: "widgets", upstream_repository: canonical) }
  let(:pr) do
    OpenStruct.new(
      number: 30, title: "Export develop",
      html_url: "https://github.com/bob/widgets/pull/30",
      user: OpenStruct.new(login: "bob"),
      head: OpenStruct.new(ref: "develop", repo: OpenStruct.new(full_name: fork.slug)),
      base: OpenStruct.new(ref: "main", repo: OpenStruct.new(full_name: canonical.slug))
    )
  end

  describe "#ingest!" do
    it "creates one umbrella Job under a new Epic and grades it" do
      job = nil
      expect {
        job = described_class.new.ingest!(repository: canonical, pr: pr, fork_pr: true)
      }.to change(Job, :count).by(1).and change(Epic, :count).by(1).and change(Workflow, :count).by(1)

      expect(job.epic_id).to eq(Epic.last.id)
      expect(Epic.last.repository).to eq(canonical)
      expect(Epic.last.title).to include("bob/widgets:develop")
      expect(Workflow.last.trigger_kind).to eq("external_pr_ingest")

      link = job.pr_links.find_by!(role: JobPrLink::ROLE_EXTERNAL_INGEST)
      expect(link.metadata).to eq("provenance" => "syrus_branch_export", "source_repo_slug" => fork.slug)
    end
  end
end
