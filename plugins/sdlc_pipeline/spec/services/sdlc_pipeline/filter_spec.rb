require "rails_helper"

RSpec.describe SdlcPipeline::Filter do
  let(:user) { Factories.user(email_address: "owner@example.com") }
  let(:other_user) { Factories.user(email_address: "other@example.com") }
  let(:repository) { Factories.repository(user: user) }
  let(:epic) { Factories.epic(repository: repository, user: user, title: "Release safety") }
  let!(:owned) { Factories.job_record(repository: repository, user: user, owner_user: user, epic: epic, issue_title: "Harden rollout") }
  let!(:other) { Factories.job_record(repository: repository, user: user, owner_user: other_user, issue_number: 99, issue_title: "Unrelated work") }

  it "compiles nested AND/OR/NOT expressions over pipeline cohort fields" do
    tree = {
      "and" => [
        { "or" => [
          { "field" => "epic_id", "op" => "is_one_of", "value" => [ epic.id ] },
          { "field" => "job_id", "op" => "is_one_of", "value" => [ other.id ] }
        ] },
        { "not" => { "field" => "owner_user_id", "op" => "is", "value" => other_user.id } }
      ]
    }

    expect(described_class.from_tree(tree, user: user).apply(Job.all)).to contain_exactly(owned)
  end

  it "searches Job and Epic identity and title fields" do
    title_filter = described_class.from_tree(
      { "and" => [ { "field" => "search", "op" => "contains", "value" => "Release safety" } ] }, user: user
    )
    id_filter = described_class.from_tree(
      { "and" => [ { "field" => "search", "op" => "contains", "value" => other.id.to_s } ] }, user: user
    )

    expect(title_filter.apply(Job.all)).to contain_exactly(owned)
    expect(id_filter.apply(Job.all)).to include(other)
  end
end
