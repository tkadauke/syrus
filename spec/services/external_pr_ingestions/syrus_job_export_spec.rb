require "rails_helper"
require "ostruct"

RSpec.describe ExternalPrIngestions::SyrusJobExport do
  let(:user) { Factories.user }
  let(:canonical) { Factories.repository(user: user, owner: "acme") }

  def pr(head_repo:, head_ref: "syrus/direct-999", number: 10)
    OpenStruct.new(
      number: number, title: "Export",
      user: OpenStruct.new(login: "casey"),
      head: OpenStruct.new(ref: head_ref, repo: OpenStruct.new(full_name: head_repo)),
      base: OpenStruct.new(ref: "main", repo: OpenStruct.new(full_name: canonical.slug))
    )
  end

  describe "#ingest! when the source Job is visible on this instance" do
    let(:fork) { Factories.repository(user: user, owner: "casey", upstream_repository: canonical) }
    let(:source_job) { Factories.job_record(user: user, repository: fork, issue_number: 5) }

    it "attaches an external_ingest JobPrLink to the existing Job instead of creating a new one" do
      exported = pr(head_repo: fork.slug, head_ref: "syrus/direct-#{source_job.id}", number: 20)

      result = nil
      expect {
        result = described_class.new.ingest!(repository: canonical, pr: exported, fork_pr: true)
      }.not_to change(Job, :count)

      expect(result).to eq(source_job)
      link = source_job.pr_links.find_by!(role: JobPrLink::ROLE_EXTERNAL_INGEST)
      expect(link.target_repository_id).to eq(canonical.id)
      expect(link.pr_number).to eq(20)
      expect(link.metadata).to eq("provenance" => "syrus_job_export", "ingest_mode" => "attached")
    end

    it "does not re-record the link on a repeated poll tick" do
      exported = pr(head_repo: fork.slug, head_ref: "syrus/direct-#{source_job.id}", number: 20)
      described_class.new.ingest!(repository: canonical, pr: exported, fork_pr: true)

      expect {
        described_class.new.ingest!(repository: canonical, pr: exported, fork_pr: true)
      }.not_to change { source_job.pr_links.count }
    end
  end

  describe "#ingest! when the source Job is not visible on this instance" do
    it "creates an imported Job with provenance metadata and grades it" do
      exported = pr(head_repo: "unlinked-instance/widgets", head_ref: "syrus/direct-777", number: 21)

      job = nil
      expect {
        job = described_class.new.ingest!(repository: canonical, pr: exported, fork_pr: true)
      }.to change(Job, :count).by(1).and change(Workflow, :count).by(1)

      expect(job.kind).to eq("external_pr")
      expect(job.external_pr_number).to eq(21)
      link = job.pr_links.find_by!(role: JobPrLink::ROLE_EXTERNAL_INGEST)
      expect(link.metadata).to eq(
        "provenance" => "syrus_job_export",
        "ingest_mode" => "imported",
        "source_repo_slug" => "unlinked-instance/widgets"
      )
    end

    it "creates an imported Job when the branch has no trailing job id" do
      exported = pr(head_repo: "unlinked-instance/widgets", head_ref: "syrus/develop", number: 22)

      expect {
        described_class.new.ingest!(repository: canonical, pr: exported, fork_pr: true)
      }.to change(Job, :count).by(1)
    end
  end
end
