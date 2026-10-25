require "rails_helper"

RSpec.describe GithubIssue, :ci_only do
  let(:repository) { Factories.repository }

  def attributes(number: 1, github_id: 101)
    {
      repository: repository,
      github_id: github_id,
      number: number,
      title: "Cached issue",
      body: "Body",
      state: "open",
      html_url: "https://github.com/acme/widgets/issues/#{number}",
      author_login: "alice",
      labels: [ { "name" => "bug", "color" => "ff0000" } ],
      github_created_at: 2.days.ago,
      github_updated_at: 1.day.ago,
      synced_at: Time.current
    }
  end

  it "belongs to a repository and preserves serialized label metadata" do
    issue = described_class.create!(attributes)

    expect(issue.reload.labels).to eq([ { "name" => "bug", "color" => "ff0000" } ])
    expect(issue.repository).to eq(repository)
  end

  it "requires repository-scoped GitHub identities and issue numbers to be unique" do
    described_class.create!(attributes)

    expect { described_class.create!(attributes(number: 2)) }.to raise_error(ActiveRecord::RecordInvalid)
    expect { described_class.create!(attributes(github_id: 102)) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "is deleted with its repository" do
    described_class.create!(attributes)

    expect { repository.destroy! }.to change(described_class, :count).by(-1)
  end
end
