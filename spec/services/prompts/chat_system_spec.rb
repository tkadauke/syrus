require "rails_helper"

RSpec.describe Prompts::ChatSystem do
  let(:repo) { repository(owner: "acme", name: "widgets") }

  it "interpolates the repository slug into the role framing" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include(<<~TEXT.strip)
      You are an embedded research and planning assistant for the
      acme/widgets repository.
    TEXT
  end

  it "frames chat as planning and proposal drafting, not editing" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("draft\nSyrus Jobs — NOT to make code changes yourself.")
    expect(out).to match(/No\s+commit or push tool is available to you here\./)
    expect(out).to include("Recommend; don't decide.")
  end

  it "renders active repository notes near the top" do
    repo.repository_notes.create!(body: "Use the App credential path for this repo.", author: "operator")
    repo.repository_notes.create!(body: "Removed context.", author: "agent", removed_at: Time.current)

    out = described_class.new(repository: repo).to_s

    expect(out).to include("Pinned context for this repository:")
    expect(out).to include("- Use the App credential path for this repo.")
    expect(out).not_to include("Removed context.")
    expect(out.index("Pinned context for this repository:")).to be < out.index("Your environment:")
  end

  it "caps rendered repository note body text" do
    repo.repository_notes.create!(body: "x" * 2_100, author: "operator")

    out = described_class.new(repository: repo).to_s

    pinned = out[/Pinned context for this repository:\n(?<body>.*?)\n\nYour environment:/m, :body]
    expect(pinned.length).to be <= 2.kilobytes + 10
    expect(pinned).to end_with("...")
  end

  it "captures the workspace expectations that should not regress" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("The workspace persists across turns.")
    expect(out).to include("switch back to the default branch when you're done")
    expect(out).to match(/Run `git fetch`\s+\(or use the `repo_info` tool\)/)
  end

  it "captures the durable chat artifact contract that should not regress" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("The durable products of this session are proposals")
    expect(out).to match(/Recurring schedules require\s+operator confirmation/)
    expect(out).to include("Use unique, stable, descriptive `slug`s")
    expect(out).to include("Express dependencies between proposals when they exist")
    expect(out).to include("Default `kind: \"syrus_issue\"`")
    expect(out).to include("Use `schedule_recurring(cron_expression, label, prompt)` only")
  end

  it "describes the shared whiteboard without snapshotting the full prompt" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("You have access to a shared whiteboard alongside this chat.")
    expect(out).to include("canvas wins for spatial relationships")
    expect(out).to include("Each shape\nyou create gets a stable id")
    expect(out).to include("Reading the canvas via `read_scene` is cheap")
  end

  it "captures the helpfulness guidance that should not regress" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("Recommend; don't decide.")
    expect(out).to include("Cite specific files and line numbers.")
    expect(out).to include("Inspect prior Jobs (`list_jobs`, `read_job`)")
  end
end
