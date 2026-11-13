require "rails_helper"
require Rails.root.join("db/migrate/20261113205458_add_origin_to_epics")

RSpec.describe AddOriginToEpics, :ci_only do
  it "keeps operator-created Epics with GitHub issue URLs operator-owned during backfill" do
    operator_epic = Factories.epic(github_issue_url: "https://github.com/acme/widgets/issues/77")
    linear_epic = Factories.epic(github_issue_url: "linear:issue:linear-parent")
    connection = ActiveRecord::Base.connection

    connection.change_column_null(:epics, :origin, true)
    operator_epic.update_column(:origin, nil)
    linear_epic.update_column(:origin, nil)

    described_class.new.migrate(:up)

    expect(operator_epic.reload.origin).to eq("operator")
    expect(linear_epic.reload.origin).to eq("linear_issue")
  ensure
    described_class.new.migrate(:up)
  end
end
