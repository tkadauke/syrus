require "rails_helper"

RSpec.describe InstanceIdentity do
  it "knows which trigger kinds are the instance's own work" do
    expect(described_class).to be_infrastructure("main_grader")
    expect(described_class).to be_infrastructure("deploy")
    expect(described_class).not_to be_infrastructure("initial")
  end

  # Grading main is not the repository owner's work. It still runs as them,
  # but saying so is what has to exist before anything can be migrated.
  it "reports the repository owner as a borrowed identity" do
    repo = Factories.repository
    resolution = described_class.for_repository(repo)

    expect(resolution.user).to eq(repo.user)
    expect(resolution).to be_borrowed
    expect(resolution).not_to be_missing
  end

  # repository.user is optional, so this is silently nobody today.
  it "reports a repository with no owner as having no identity" do
    repo = Factories.repository
    repo.update_columns(user_id: nil)

    resolution = described_class.for_repository(repo.reload)

    expect(resolution).to be_missing
    expect(resolution.user).to be_nil
  end

  it "counts the repositories whose instance work has nobody to run as" do
    repo = Factories.repository
    expect(described_class.repositories_without_identity).not_to include(repo)

    repo.update_columns(user_id: nil)
    expect(described_class.repositories_without_identity).to include(repo)
  end
end
