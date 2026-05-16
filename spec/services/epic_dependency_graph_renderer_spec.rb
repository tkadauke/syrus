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

  it "renders internal, cross-Epic, and manual dependency edges with distinct Mermaid styles" do
    epic = Factories.epic(user: user, repository: repo, title: "Forum restoration")
    neighbor = Factories.epic(user: user, repository: repo, title: "Aqueduct repair")
    jobs = [
      epic_job(epic, 1, "Survey ruins"),
      epic_job(epic, 2, "Rebuild columns"),
      epic_job(epic, 3, "Hang banner"),
      epic_job(epic, 4, "Invite senate"),
      epic_job(epic, 5, "Declare victory")
    ]
    outside = epic_job(neighbor, 6, "Deliver marble")

    JobDependency.create!(job: jobs[1], depends_on_job: jobs[0], source: "manual", created_by_user: user)
    JobDependency.create!(job: jobs[2], depends_on_job: jobs[1], source: "manual", created_by_user: user)
    JobDependency.create!(job: jobs[4], depends_on_job: jobs[3], source: "manual", created_by_user: user)
    JobDependency.create!(job: jobs[0], depends_on_job: outside, source: "manual", created_by_user: user)
    EpicDependency.create!(epic: epic, depends_on_epic: neighbor, derived: false)

    result = described_class.new(epic).render

    expect(result.node_count).to eq(8)
    expect(result.definition).to include("flowchart LR")
    expect(result.definition).to include("job_#{jobs[0].id}[\"#1 Survey ruins\"]")
    expect(result.definition).to include("job_#{outside.id}[\"#{neighbor.display_number} / #6 Deliver marble\"]")
    expect(result.definition).to include("job_#{jobs[0].id} --> job_#{jobs[1].id}")
    expect(result.definition).to include("job_#{outside.id} -.-> job_#{jobs[0].id}")
    expect(result.definition).to include("epic_#{neighbor.id} ==> epic_#{epic.id}")
    expect(result.definition).to include("stroke:#374151,stroke-width:2px")
    expect(result.definition).to include("stroke:#7c3aed,stroke-width:2px,stroke-dasharray:5 4")
    expect(result.definition).to include("stroke:#111827,stroke-width:4px")
  end

  it "renders the full transitive closure when requested" do
    root = Factories.epic(user: user, repository: repo, title: "Forum restoration")
    middle = Factories.epic(user: user, repository: repo, title: "Road paving")
    leaf = Factories.epic(user: user, repository: repo, title: "Marble delivery")
    root_job = epic_job(root, 10, "Survey ruins")
    middle_job = epic_job(middle, 11, "Lay stones")
    leaf_job = epic_job(leaf, 12, "Haul marble")

    JobDependency.create!(job: middle_job, depends_on_job: root_job, source: "manual", created_by_user: user)
    JobDependency.create!(job: leaf_job, depends_on_job: middle_job, source: "manual", created_by_user: user)

    adjacent = described_class.new(root).render
    transitive = described_class.new(root, depth: :transitive).render

    expect(adjacent.definition).to include("job_#{middle_job.id}")
    expect(adjacent.definition).not_to include("job_#{leaf_job.id}")
    expect(transitive.definition).to include("job_#{middle_job.id}")
    expect(transitive.definition).to include("job_#{leaf_job.id}")
    expect(transitive.node_count).to eq(6)
    expect(transitive.summarized).to be false
  end

  it "summarizes large transitive graphs into Epic-level nodes" do
    root = Factories.epic(user: user, repository: repo, title: "Forum restoration")
    middle = Factories.epic(user: user, repository: repo, title: "Road paving")
    root_job = epic_job(root, 20, "Survey ruins")
    previous = root_job

    4.times do |index|
      job = epic_job(middle, 21 + index, "Stone #{index}")
      JobDependency.create!(job: job, depends_on_job: previous, source: "manual", created_by_user: user)
      previous = job
    end

    result = described_class.new(root, depth: :transitive, summary_node_threshold: 3).render

    expect(result.summarized).to be true
    expect(result.raw_node_count).to eq(7)
    expect(result.definition).to include("epic_#{root.id}[\"#{root.display_number} Forum restoration (1 Job)\"]")
    expect(result.definition).to include("epic_#{middle.id}[\"#{middle.display_number} Road paving (4 Jobs)\"]")
    expect(result.definition).not_to include("job_#{previous.id}")
  end
end
