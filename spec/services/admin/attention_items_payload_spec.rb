require "rails_helper"

RSpec.describe Admin::AttentionItemsPayload do
  it "defaults to open items, most urgent first" do
    repo = Factories.repository
    urgent = Factories.attention_item(repository: repo, urgency: "urgent", title: "urgent one")
    normal = Factories.attention_item(repository: repo, urgency: "normal", title: "normal one")
    decided = Factories.attention_item(repository: repo, title: "already decided")
    decided.decide!(resolution: "dismissed", user: repo.user, reason: "known issue")

    json = described_class.new(params: {}).index_json

    ids = json[:items].map { |item| item[:id] }
    expect(ids).to eq([ urgent.id, normal.id ])
    expect(ids).not_to include(decided.id)
  end

  it "serializes evidence, adjudication, problem label, and actions" do
    repo = Factories.repository
    job = Factories.job(repository: repo)
    item = Factories.attention_item(
      repository: repo,
      job: job,
      evidence: { "grader_name" => "rspec" },
      adjudication: { "verdict" => "inconclusive", "reason" => "no opinion" },
      actions: [ { "action_key" => "retry_job", "label" => "Retry from the failed step", "payload" => { "job_id" => job.id } } ]
    )

    json = described_class.new(params: {}).index_json
    row = json[:items].find { |i| i[:id] == item.id }

    expect(row).to include(
      problem_code: "grader_failure",
      problem_label: "Grader failure",
      evidence: { "grader_name" => "rspec" },
      adjudication: { "verdict" => "inconclusive", "reason" => "no opinion" }
    )
    expect(row[:job]).to include(id: job.id, slug: job.slug)
    expect(row[:actions]).to eq([
      { action_key: "retry_job", label: "Retry from the failed step", detail: "job_id: #{job.id}", payload: { "job_id" => job.id } }
    ])
  end

  it "filters by queue, urgency, and repository" do
    repo = Factories.repository
    other_repo = Factories.repository
    operator_item = Factories.attention_item(repository: repo, queue: "operator")
    Factories.attention_item(repository: repo, queue: "triage")
    Factories.attention_item(repository: other_repo, queue: "operator")

    json = described_class.new(params: { queue: "operator", repository_id: repo.id.to_s }).index_json

    expect(json[:items].map { |item| item[:id] }).to eq([ operator_item.id ])
  end

  it "renders a single item for post-mutation re-rendering" do
    item = Factories.attention_item(repository: Factories.repository)

    rendered = described_class.render_item(item)

    expect(rendered[:id]).to eq(item.id)
  end
end
