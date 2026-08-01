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
    expect(result.nodes).to contain_exactly(
      hash_including(id: "epic_#{epic.id}", kind: "epic", label: "#{epic.slug} Forum restoration",
                     state: epic.state, epic_id: epic.id, url: "/epics/#{epic.slug}", is_focal: true)
    )
    expect(result.edges).to be_empty
  end

  it "renders an Epic dependency touching the current Epic" do
    epic = Factories.epic(user: user, repository: repo, title: "Forum restoration")
    blocker = Factories.epic(user: user, repository: repo, title: "Aqueduct repair")
    EpicDependency.create!(epic: epic, depends_on_epic: blocker, derived: false)

    result = described_class.new(epic).render

    expect(result.node_count).to eq(2)
    expect(result.epic_dependency_count).to eq(1)
    expect(result.job_blocker_count).to eq(0)
    expect(result.nodes).to include(
      hash_including(id: "epic_#{epic.id}", kind: "epic", is_focal: true, epic_id: epic.id),
      hash_including(id: "epic_#{blocker.id}", kind: "epic", is_focal: false, epic_id: blocker.id)
    )
    expect(result.edges).to contain_exactly(
      { from_id: "epic_#{blocker.id}", to_id: "epic_#{epic.id}" }
    )
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
    expect(result.nodes).to include(
      hash_including(id: "job_#{blocker.id}", kind: "job", label: "#{other_epic.slug} / #{blocker.slug} Deliver marble",
                     state: blocker.state, epic_id: other_epic.id, url: "/jobs/#{blocker.slug}", is_focal: false)
    )
    expect(result.edges).to contain_exactly(
      { from_id: "job_#{blocker.id}", to_id: "epic_#{epic.id}" }
    )
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
    expect(result.nodes).to include(
      hash_including(id: "job_#{blocker.id}", kind: "job", epic_id: nil, is_focal: false)
    )
    expect(result.edges).to contain_exactly(
      { from_id: "job_#{blocker.id}", to_id: "epic_#{epic.id}" }
    )
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
    expect(result.nodes.size).to eq(5)
    expect(result.nodes.map { |n| n[:id] }).to contain_exactly(
      "epic_#{epic.id}", "epic_#{other_epic.id}", "epic_#{dependent_epic.id}",
      "job_#{blocker.id}", "job_#{epicless.id}"
    )
    expect(result.nodes.select { |n| n[:is_focal] }.map { |n| n[:id] }).to eq([ "epic_#{epic.id}" ])
    expect(result.edges.size).to eq(4)
    expect(result.edges).to include(
      { from_id: "epic_#{other_epic.id}", to_id: "epic_#{epic.id}" },
      { from_id: "epic_#{epic.id}", to_id: "epic_#{dependent_epic.id}" },
      { from_id: "job_#{blocker.id}", to_id: "epic_#{epic.id}" },
      { from_id: "job_#{epicless.id}", to_id: "epic_#{epic.id}" }
    )
  end

  it "does not render child Jobs or internal Job dependencies for the current Epic" do
    epic = Factories.epic(user: user, repository: repo, title: "Forum restoration")
    first = epic_job(epic, 10, "Survey ruins")
    second = epic_job(epic, 11, "Rebuild columns")
    JobDependency.create!(job: second, depends_on_job: first, source: "manual", created_by_user: user)

    result = described_class.new(epic).render

    expect(result).to be_empty
    expect(result.nodes.map { |n| n[:id] }).not_to include("job_#{first.id}", "job_#{second.id}")
    expect(result.nodes.map { |n| n[:label] }).not_to include(/#{first.slug} Survey ruins/, /#{second.slug} Rebuild columns/)
  end
end
