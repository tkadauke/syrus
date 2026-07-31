require "rails_helper"
require Rails.root.join("db/migrate/20260731171000_remove_inherited_epic_dependency_policy")

RSpec.describe RemoveInheritedEpicDependencyPolicy do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  after do
    migration.up
    Epic.reset_column_information
  end

  it "backfills inherited Epics to the repository policy and changes the default to linear" do
    migration.down
    Epic.reset_column_information

    linear_repository = Factories.repository(epic_dependency_policy: "linear")
    nonlinear_repository = Factories.repository(epic_dependency_policy: "nonlinear")
    linear_epic = Factories.epic(user: linear_repository.user, repository: linear_repository, epic_dependency_policy: "linear")
    nonlinear_epic = Factories.epic(user: nonlinear_repository.user, repository: nonlinear_repository, epic_dependency_policy: "linear")
    concrete_epic = Factories.epic(user: nonlinear_repository.user, repository: nonlinear_repository, epic_dependency_policy: "linear")
    Epic.where(id: [ linear_epic.id, nonlinear_epic.id ]).update_all(epic_dependency_policy: "inherit")

    migration.up
    Epic.reset_column_information

    epic_column = connection.columns(:epics).find { |column| column.name == "epic_dependency_policy" }
    expect(epic_column.default).to eq("linear")
    expect(linear_epic.reload.epic_dependency_policy).to eq("linear")
    expect(nonlinear_epic.reload.epic_dependency_policy).to eq("nonlinear")
    expect(concrete_epic.reload.epic_dependency_policy).to eq("linear")
  end
end
