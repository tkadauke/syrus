require "rails_helper"

# Answering a question resumes its parked Run. When the resume cannot happen
# (for example, a blocked auxiliary Workflow released its Job lock and a newer
# Workflow took it, so reactivating the WorkUnit raises a lock conflict), the
# answer must not be consumed: otherwise the question is no longer active, the
# Run stays blocked, and the operator has nothing left to answer.
RSpec.describe "Answering a question whose resume fails" do
  let(:user) { Factories.user }
  let(:run) { Factories.job(user: user).initial_run }
  let(:workflow) { run.workflow }

  before do
    run.job.update_columns(state: "running")
    workflow.update_columns(state: "blocked", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    run.step.update_columns(state: "blocked", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    run.update_columns(state: "blocked", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    attach_work_unit(workflow, state: "failed")
  end

  def ask!
    AgentQuestion.create!(
      run: run, questions: [ { "question" => "What next?", "options" => nil, "multiple" => false } ],
      asked_at: Time.current
    )
  end

  it "keeps the question answerable when the resume raises" do
    question = ask!
    # The conflicting newer WorkUnit is out of scope here; the raise is what
    # WorkUnit#ensure_active_locks! does when another unit holds the Job lock.
    allow(WorkUnits::WorkflowLifecycle).to receive(:started!)
      .and_raise(WorkUnits::Launcher::LockConflict.new(lock_key: "job:#{run.job_id}", work_unit: nil))
    expect_any_instance_of(Run).not_to receive(:reenqueue!)

    expect {
      question.answer!(answers: [ "Use the other credential" ], answered_by: user, source: "web")
    }.to raise_error(WorkUnits::Launcher::LockConflict)

    expect(question.reload).to be_active
    expect(question.events.where(event_type: "answered")).to be_empty
    expect(run.reload.state).to eq("blocked")
    expect(workflow.reload.state).to eq("blocked")
  end

  it "still records an answer for a run that is not parked yet" do
    run.update_columns(state: "running")
    run.step.update_columns(state: "running")
    workflow.update_columns(state: "running")
    question = ask!

    expect(question.answer!(answers: [ "Go" ], answered_by: user, source: "web")).to eq(true)
    expect(question.reload).not_to be_active
    expect(run.reload.state).to eq("running")
  end
end
