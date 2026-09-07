require "rails_helper"
require Rails.root.join("db/migrate/20260907013044_remove_nonlinear_epic_dependency_policy")

RSpec.describe RemoveNonlinearEpicDependencyPolicy, :ci_only do
  let(:migration) { described_class.new }

  it "backfills nonlinear repositories and epics to linear" do
    repository = Factories.repository
    repository.update_column(:epic_dependency_policy, "nonlinear")
    other_repository = Factories.repository(epic_dependency_policy: "linear")
    epic = Factories.epic(user: repository.user, repository: repository)
    epic.update_column(:epic_dependency_policy, "nonlinear")
    linear_epic = Factories.epic(user: other_repository.user, repository: other_repository, epic_dependency_policy: "linear")

    migration.up

    expect(repository.reload.epic_dependency_policy).to eq("linear")
    expect(epic.reload.epic_dependency_policy).to eq("linear")
    expect(other_repository.reload.epic_dependency_policy).to eq("linear")
    expect(linear_epic.reload.epic_dependency_policy).to eq("linear")
  end

  it "is a no-op when no nonlinear rows exist" do
    repository = Factories.repository(epic_dependency_policy: "linear")
    epic = Factories.epic(user: repository.user, repository: repository, epic_dependency_policy: "linear")

    expect { migration.up }.not_to change { repository.reload.epic_dependency_policy }
    expect(epic.reload.epic_dependency_policy).to eq("linear")
  end

  it "has a down migration that leaves data untouched" do
    repository = Factories.repository
    repository.update_column(:epic_dependency_policy, "nonlinear")

    migration.up
    expect { migration.down }.not_to change { repository.reload.epic_dependency_policy }
  end
end
