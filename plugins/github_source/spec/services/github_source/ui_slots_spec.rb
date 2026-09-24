require "rails_helper"

RSpec.describe GithubSource::UiSlots do
  before { SmartFolder.ensure_builtins_for_subject!("job") }

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:inbox_folder) { SmartFolder.find_builtin_by_attention("inbox") }
  let(:context) do
    {
      user: user,
      subject: "job",
      active_smart_folder: inbox_folder,
      active_repositories_scope: Repository.active
    }
  end

  it "returns nothing for non-dashboard notice slots" do
    expect(described_class.ui_slots(slot: "job.detail", context: context)).to eq([])
  end

  it "returns nothing outside the Jobs inbox" do
    repository.update_columns(untagged_open_issue_count: 3)

    expect(described_class.ui_slots(slot: "dashboard.jobs.notice", context: context.merge(subject: "epic"))).to eq([])
    expect(described_class.ui_slots(slot: "dashboard.jobs.notice", context: context.merge(active_smart_folder: nil))).to eq([])
  end

  it "returns nothing when no active repositories have unlabeled open issues" do
    repository.update_columns(untagged_open_issue_count: 0)

    expect(described_class.ui_slots(slot: "dashboard.jobs.notice", context: context)).to eq([])
  end

  it "contributes the unlabeled GitHub issues banner with plugin-owned paths" do
    repository.update_columns(untagged_open_issue_count: 3)
    other = Factories.repository(user: user, owner: "acme", name: "widgets2", untagged_open_issue_count: 2)
    Factories.repository(user: user, owner: "acme", name: "widgets3", untagged_open_issue_count: 0)

    panel = described_class.ui_slots(slot: "dashboard.jobs.notice", context: context).sole

    expect(panel).to include(
      id: "github_source.untagged_issues",
      component: "github_source/UntaggedIssuesBanner",
      order: 10
    )
    expect(panel.dig(:props, :untagged_issues, :total)).to eq(5)
    expect(panel.dig(:props, :untagged_issues, :repositories)).to contain_exactly(
      { id: repository.id, slug: repository.slug, count: 3, issues_path: "/repositories/#{repository.id}/plugin/issues" },
      { id: other.id, slug: other.slug, count: 2, issues_path: "/repositories/#{other.id}/plugin/issues" }
    )
  end
end
