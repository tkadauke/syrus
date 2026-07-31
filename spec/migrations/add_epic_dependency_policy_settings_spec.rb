require "rails_helper"
require Rails.root.join("db/migrate/20260731120000_add_epic_dependency_policy_settings")

RSpec.describe AddEpicDependencyPolicySettings do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  after do
    migration.up
    Repository.reset_column_information
    Epic.reset_column_information
  end

  it "adds repository and Epic policy defaults and is idempotent" do
    migration.down

    expect(connection.column_exists?(:repositories, :epic_dependency_policy)).to be(false)
    expect(connection.column_exists?(:epics, :epic_dependency_policy)).to be(false)

    migration.up
    migration.up
    Repository.reset_column_information
    Epic.reset_column_information

    repository_column = connection.columns(:repositories).find { |column| column.name == "epic_dependency_policy" }
    epic_column = connection.columns(:epics).find { |column| column.name == "epic_dependency_policy" }

    expect(repository_column.default).to eq("linear")
    expect(repository_column.null).to be(false)
    expect(epic_column.default).to eq("inherit")
    expect(epic_column.null).to be(false)

    repository = Factories.repository
    epic = Factories.epic(user: repository.user, repository: repository)

    expect(repository.epic_dependency_policy).to eq("linear")
    expect(epic.epic_dependency_policy).to eq("inherit")
  end
end
