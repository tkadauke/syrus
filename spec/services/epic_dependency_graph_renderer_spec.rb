require "rails_helper"

RSpec.describe EpicDependencyGraphRenderer do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def epic_job(epic, number, title)
    Factories.job_record(
      user: user,
      repository: repo,
      epic: epic,
      issue_number: number,
      issue_title: title
    )
  end

  it "returns an empty-state result when the Epic has no external dependencies" do
    epic = Factories.epic(user: user, repository: repo, title: "Forum restoration")
    epic_job(epic, 1, "Survey ruins")

    result = described_class.new(epic).render

    expect(result).to be_empty
    expect(result.external_dependencies?).to be false
    expect(result.node_count).to eq(1)
    expect(result.epic_dependency_count).to eq(0)
    expect(result.job_blocker_count).to eq(0)
    expect(result.definition).to include("epic_#{epic.id}[\"#{epic.display_number} Forum restoration\"]")
  end

  it "renders an Epic dependency touching the current Epic" do
    epic = Factories.epic(user: user, repository: repo, title: "Forum restoration")
    blocker = Factories.epic(user: user, repository: repo, title: "Aqueduct repair")
    EpicDependency.create!(epic: epic, depends_on_epic: blocker, derived: false)

    result = described_class.new(epic).render

    expect(result.node_count).to eq(2)
    expect(result.epic_dependency_count).to eq(1)
    expect(result.job_blocker_count).to eq(0)
    expect(result.definition).to include("epic_#{epic.id} --> epic_#{blocker.id}")
    expect(result.definition).to include("class epic_#{epic.id} currentEpic")
    expect(result.definition).to include("class epic_#{blocker.id} otherEpic")
  end

  it "renders an external blocker Job in another Epic" do
    epic = Factories.epic(user: user, repository: repo, title: "Forum restoration")
    other_epic = Factories.epic(user: user, repository: repo, title: "Marble delivery")
    local_job = epic_job(epic, 2, "Rebuild columns")
    blocker = epic_job(other_epic, 3, "Deliver marble")
    JobDependency.create!(job: local_job, depends_on_job: blocker, source: "manual", created_by_user: user)
    EpicDependency.delete_all

    result = described_class.new(epic).render

    expect(result.node_count).to eq(2)
    expect(result.epic_dependency_count).to eq(0)
    expect(result.job_blocker_count).to eq(1)
    expect(result.definition).to include("epic_#{epic.id} --> job_#{blocker.id}")
    expect(result.definition).to include("job_#{blocker.id}[\"#{other_epic.display_number} / #3 Deliver marble\"]")
    expect(result.definition).to include("class job_#{blocker.id} epicJobBlocker")
  end

  it "renders an Epic-less blocker Job with dashed styling" do
    epic = Factories.epic(user: user, repository: repo, title: "Forum restoration")
    local_job = epic_job(epic, 4, "Raise scaffolding")
    blocker = Factories.job_record(
      user: user,
      repository: repo,
      epic: nil,
      issue_number: 5,
      issue_title: "Find spare stones"
    )
    JobDependency.create!(job: local_job, depends_on_job: blocker, source: "manual", created_by_user: user)

    result = described_class.new(epic).render

    expect(result.node_count).to eq(2)
    expect(result.epic_dependency_count).to eq(0)
    expect(result.job_blocker_count).to eq(1)
    expect(result.definition).to include("job_#{blocker.id}[\"No Epic / #5 Find spare stones\"]")
    expect(result.definition).to include("class job_#{blocker.id} epiclessJobBlocker")
    expect(result.definition).to include("classDef epiclessJobBlocker")
    expect(result.definition).to include("stroke-dasharray:5 4")
  end

  it "combines Epic dependencies and external blocker Jobs without duplicates" do
    epic = Factories.epic(user: user, repository: repo, title: "Forum restoration")
    other_epic = Factories.epic(user: user, repository: repo, title: "Marble delivery")
    dependent_epic = Factories.epic(user: user, repository: repo, title: "Victory parade")
    local_a = epic_job(epic, 6, "Set foundations")
    local_b = epic_job(epic, 7, "Raise columns")
    blocker = epic_job(other_epic, 8, "Deliver marble")
    epicless = Factories.job_record(
      user: user,
      repository: repo,
      epic: nil,
      issue_number: 9,
      issue_title: "Borrow cart"
    )

    EpicDependency.create!(epic: dependent_epic, depends_on_epic: epic, derived: false)
    JobDependency.create!(job: local_a, depends_on_job: blocker, source: "manual", created_by_user: user)
    JobDependency.create!(job: local_b, depends_on_job: blocker, source: "manual", created_by_user: user)
    JobDependency.create!(job: local_b, depends_on_job: epicless, source: "manual", created_by_user: user)

    result = described_class.new(epic).render

    expect(result.node_count).to eq(5)
    expect(result.epic_dependency_count).to eq(2)
    expect(result.job_blocker_count).to eq(2)
    expect(result.definition.scan("job_#{blocker.id}[")).to contain_exactly("job_#{blocker.id}[")
    expect(result.definition.scan("epic_#{epic.id} --> job_#{blocker.id}")).to contain_exactly("epic_#{epic.id} --> job_#{blocker.id}")
    expect(result.definition).to include("epic_#{epic.id} --> epic_#{other_epic.id}")
    expect(result.definition).to include("epic_#{dependent_epic.id} --> epic_#{epic.id}")
    expect(result.definition).to include("epic_#{epic.id} --> job_#{epicless.id}")
  end

  it "does not render child Jobs or internal Job dependencies for the current Epic" do
    epic = Factories.epic(user: user, repository: repo, title: "Forum restoration")
    first = epic_job(epic, 10, "Survey ruins")
    second = epic_job(epic, 11, "Rebuild columns")
    JobDependency.create!(job: second, depends_on_job: first, source: "manual", created_by_user: user)

    result = described_class.new(epic).render

    expect(result).to be_empty
    expect(result.definition).not_to include("job_#{first.id}")
    expect(result.definition).not_to include("job_#{second.id}")
    expect(result.definition).not_to include("#10 Survey ruins")
    expect(result.definition).not_to include("#11 Rebuild columns")
  end
end
