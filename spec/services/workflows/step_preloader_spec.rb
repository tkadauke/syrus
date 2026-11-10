require "rails_helper"

RSpec.describe Workflows::StepPreloader do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def workflow_with_steps(issue_number, positions)
    job = Factories.job(user: user, repository: repository, issue_number: issue_number)
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", state: "running")
    positions.each do |position|
      Step.create!(workflow: workflow, kind: "grader", position: position, state: "queued",
        details: { "output" => "x" * 1_024 })
    end
    workflow
  end

  it "attaches Steps in position order" do
    workflow = workflow_with_steps(200, [ 3, 1, 2 ])

    attached = described_class.attach!([ Workflow.find(workflow.id) ]).first

    expect(attached.steps.map(&:position)).to eq([ 1, 2, 3 ])
    expect(attached.association(:steps)).to be_loaded
  end

  it "orders by id when two Steps share a position" do
    workflow = workflow_with_steps(201, [ 1, 1 ])
    expected = workflow.steps.reorder(:id).pluck(:id)

    attached = described_class.attach!([ Workflow.find(workflow.id) ]).first

    expect(attached.steps.map(&:id)).to eq(expected)
  end

  it "points each Step back at the Workflow instance it was attached to" do
    workflow = workflow_with_steps(202, [ 1 ])

    attached = described_class.attach!([ Workflow.find(workflow.id) ]).first

    # A real preload sets this inverse. Without it `step.workflow` re-queries
    # and returns a second instance holding database state, which disagrees
    # with the caller's instance the moment something moves the Workflow on.
    expect(attached.steps.first.workflow).to equal(attached)
  end

  it "does not re-query for the parent when walking Steps back to the Workflow" do
    workflow = workflow_with_steps(203, [ 1, 2 ])
    attached = described_class.attach!([ Workflow.find(workflow.id) ]).first

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    begin
      attached.steps.each { |step| step.workflow.state }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    expect(statements).to be_empty
  end

  it "emits no sort when loading Steps across several Workflows" do
    workflows = [ workflow_with_steps(204, [ 1, 2 ]), workflow_with_steps(205, [ 1 ]) ]
    loaded = Workflow.where(id: workflows.map(&:id)).to_a

    offenders = wide_row_sort_statements { described_class.attach!(loaded) }

    expect(offenders).to be_empty
  end

  it "attaches an empty collection to a Workflow with no Steps" do
    job = Factories.job(user: user, repository: repository, issue_number: 206)
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", state: "running")

    attached = described_class.attach!([ Workflow.find(workflow.id) ]).first

    expect(attached.steps).to eq([])
    expect(attached.association(:steps)).to be_loaded
  end

  it "handles an empty input without querying" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    begin
      expect(described_class.attach!([])).to eq([])
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    expect(statements).to be_empty
  end
end
