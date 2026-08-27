require "rails_helper"

RSpec.describe PromotionDispatcher do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }

  before do
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
      instance_double(DeliveryPolicy, promotion_source_branch: "develop", promotion_target_branch: "main")
    )
    # Same seam MaybeDeployJob/MainGraderWorkflowJob specs use: exercise the
    # instantiate/dispatch wiring without depending on WorkUnits::Launcher's
    # Scheduler gates (agent concurrency, provider availability, ...).
    allow(StepDispatcher).to receive(:start_workflow)
  end

  it "creates a synthetic direct anchor Job with no GitHub issue" do
    described_class.call!(repository: repository)

    job = Job.order(:id).last
    expect(job.kind).to eq("direct")
    expect(job.issue_number).to be_nil
    expect(job.repository).to eq(repository)
    expect(job.user).to eq(user)
    expect(job.issue_title).to eq("Promote develop into main")
  end

  it "dispatches a Workflows::Promotion workflow seeded with the resolved refs" do
    described_class.call!(repository: repository)

    job = Job.order(:id).last
    workflow = job.workflows.last
    expect(workflow.trigger_kind).to eq("promotion")
    expect(workflow.artifact("promotion_source_branch")).to eq("develop")
    expect(workflow.artifact("promotion_target_branch")).to eq("main")
  end

  it "starts the workflow via StepDispatcher" do
    described_class.call!(repository: repository)

    job = Job.order(:id).last
    workflow = job.workflows.last
    expect(StepDispatcher).to have_received(:start_workflow).with(workflow)
  end

  it "honors explicit source_branch/target_branch overrides instead of resolving from DeliveryPolicy" do
    described_class.call!(repository: repository, source_branch: "release/1.0", target_branch: "main")

    workflow = Job.order(:id).last.workflows.last
    expect(workflow.artifact("promotion_source_branch")).to eq("release/1.0")
  end

  it "defaults the anchor Job's user to the repository owner when no user is given" do
    described_class.call!(repository: repository)

    expect(Job.order(:id).last.user).to eq(repository.user)
  end
end
