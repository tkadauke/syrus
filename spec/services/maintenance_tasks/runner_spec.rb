require "rails_helper"

RSpec.describe MaintenanceTasks::Runner do
  class SpecDirtyStepMaintenanceDefinition < MaintenanceTasks::Definitions::Base
    key "spec_dirty_step"
    title "Spec dirty step"
    summary "Exercises dirty step progress handling."
    category "cleanup"
    recurrence "one_off"
    required_role "admin"

    def estimate_total_units = 1

    def perform_batch(task)
      task.current_step_key = "retire"
      task.current_step_title = "Retire stale cards"
      Result.new(done: true, processed: 1, failed: 0, message: "Done.", level: "info")
    end
  end

  class SpecProgressRepairMaintenanceDefinition < MaintenanceTasks::Definitions::Base
    key "spec_progress_repair"
    title "Spec progress repair"
    summary "Exercises progress accounting repair."
    category "cleanup"
    recurrence "one_off"
    required_role "admin"

    def estimate_total_units = 3

    def perform_batch(task)
      task.current_step_key = "repair"
      task.current_step_title = "Repair progress"
      Result.new(done: false, processed: 1, failed: 0, message: "Processed one.", level: "progress")
    end
  end

  it "persists step progress when the definition mutates the task before locking" do
    task = MaintenanceTask.create!(
      definition_key: "spec_dirty_step",
      task_key: "spec:dirty-step",
      state: "running",
      recurrence: "one_off",
      category: "cleanup",
      title: "Spec dirty step",
      summary: "Exercises dirty step progress handling.",
      trigger_kind: "spec",
      trigger_key: "dirty-step",
      required_role: "admin",
      total_units: 1
    )

    allow(MaintenanceTasks::Registry).to receive(:fetch)
      .with("spec_dirty_step")
      .and_return(SpecDirtyStepMaintenanceDefinition.new)

    described_class.new(task).call

    expect(task.reload).to have_attributes(
      state: "succeeded",
      completed_units: 1,
      current_step_key: "retire",
      current_step_title: "Retire stale cards",
      last_error: nil
    )
    expect(task.events.last).to have_attributes(
      level: "info",
      step_key: "retire",
      step_title: "Retire stale cards",
      message: "Done."
    )
  end

  it "repairs stale totals when completed progress already exceeds total units" do
    task = MaintenanceTask.create!(
      definition_key: "spec_progress_repair",
      task_key: "spec:progress-repair",
      state: "running",
      recurrence: "one_off",
      category: "cleanup",
      title: "Spec progress repair",
      summary: "Exercises progress accounting repair.",
      trigger_kind: "spec",
      trigger_key: "progress-repair",
      required_role: "admin",
      total_units: 40,
      completed_units: 60
    )

    allow(MaintenanceTasks::Registry).to receive(:fetch)
      .with("spec_progress_repair")
      .and_return(SpecProgressRepairMaintenanceDefinition.new)

    described_class.new(task).call

    expect(task.reload).to have_attributes(
      state: "running",
      completed_units: 61,
      total_units: 64
    )
  end

  class SpecCheckpointProgressMaintenanceDefinition < MaintenanceTasks::Definitions::Base
    key "spec_checkpoint_progress"
    title "Spec checkpoint progress"
    summary "Exercises checkpoint persistence across sequential batches."
    category "cleanup"
    recurrence "one_off"
    required_role "admin"

    def estimate_total_units = 2

    def perform_batch(task)
      task.current_step_key = "process"
      task.current_step_title = "Process item"

      next_id = (Array(task.checkpoint["processed_ids"]).max || 0) + 1
      task.checkpoint_will_change!
      task.checkpoint["processed_ids"] = Array(task.checkpoint["processed_ids"]) + [ next_id ]

      Result.new(done: next_id >= 2, processed: 1, failed: 0, message: "Processed item #{next_id}.", level: "progress")
    end
  end

  it "persists checkpoint mutations across sequential calls so resumable definitions actually advance" do
    task = MaintenanceTask.create!(
      definition_key: "spec_checkpoint_progress",
      task_key: "spec:checkpoint-progress",
      state: "running",
      recurrence: "one_off",
      category: "cleanup",
      title: "Spec checkpoint progress",
      summary: "Exercises checkpoint persistence across sequential batches.",
      trigger_kind: "spec",
      trigger_key: "checkpoint-progress",
      required_role: "admin",
      total_units: 2
    )

    allow(MaintenanceTasks::Registry).to receive(:fetch)
      .with("spec_checkpoint_progress")
      .and_return(SpecCheckpointProgressMaintenanceDefinition.new)

    described_class.new(task).call
    expect(task.reload.checkpoint["processed_ids"]).to eq([ 1 ])
    expect(task).to have_attributes(current_step_key: "process", current_step_title: "Process item")

    described_class.new(task).call
    expect(task.reload).to have_attributes(
      state: "succeeded",
      checkpoint: hash_including("processed_ids" => [ 1, 2 ]),
      current_step_key: "process",
      current_step_title: "Process item"
    )
  end

  it "advances Definitions::LandedCommitsBackfill to the next candidate repository across sequential runner calls" do
    definition = MaintenanceTasks::Definitions::LandedCommitsBackfill.new
    user = Factories.user
    repository_one = Factories.repository(user: user)
    repository_two = Factories.repository(user: user)
    Factories.job_record(user: user, repository: repository_one, state: "closed", issue_number: 300, pr_number: 301, landed_sha: "sha1")
    Factories.job_record(user: user, repository: repository_two, state: "closed", issue_number: 302, pr_number: 303, landed_sha: "sha2")

    ordered_repository_ids = Repository.where(id: [ repository_one.id, repository_two.id ]).order(:id).pluck(:id)

    task = MaintenanceTask.create!(
      definition_key: definition.key,
      task_key: "spec:landed-commits-backfill-runner",
      state: "running",
      recurrence: definition.recurrence,
      category: definition.category,
      title: definition.title,
      summary: definition.summary,
      trigger_kind: "spec",
      trigger_key: definition.key,
      required_role: definition.required_role,
      total_units: definition.estimate_total_units,
      batch_size: definition.batch_size,
      max_parallelism: definition.max_parallelism
    )

    allow(MaintenanceTasks::Registry).to receive(:fetch).with(definition.key).and_return(definition)

    service_result = Jobs::LandedCommitsBackfill::Result.new(checked: 1, recorded: 1, commits_recorded: 1, skipped: 0, errors: 0)
    service = instance_double(Jobs::LandedCommitsBackfill, call: service_result)
    allow(Jobs::LandedCommitsBackfill).to receive(:new).and_return(service)

    described_class.new(task).call
    expect(task.reload.checkpoint["processed_repository_ids"]).to eq([ ordered_repository_ids.first ])

    described_class.new(task).call
    expect(task.reload.checkpoint["processed_repository_ids"]).to match_array(ordered_repository_ids)
  end

  it "fails Definitions::LandedCommitsBackfill after a pass with unresolved repository errors" do
    definition = MaintenanceTasks::Definitions::LandedCommitsBackfill.new
    user = Factories.user
    repository = Factories.repository(user: user)
    Factories.job_record(user: user, repository: repository, state: "closed", issue_number: 304, pr_number: 305, landed_sha: "sha3")

    task = MaintenanceTask.create!(
      definition_key: definition.key,
      task_key: "spec:landed-commits-backfill-unresolved",
      state: "running",
      recurrence: definition.recurrence,
      category: definition.category,
      title: definition.title,
      summary: definition.summary,
      trigger_kind: "spec",
      trigger_key: definition.key,
      required_role: definition.required_role,
      total_units: definition.estimate_total_units,
      batch_size: definition.batch_size,
      max_parallelism: definition.max_parallelism
    )

    allow(MaintenanceTasks::Registry).to receive(:fetch).with(definition.key).and_return(definition)

    service_result = Jobs::LandedCommitsBackfill::Result.new(checked: 1, recorded: 0, commits_recorded: 0, skipped: 0, errors: 1)
    retry_result = Jobs::LandedCommitsBackfill::Result.new(checked: 1, recorded: 1, commits_recorded: 1, skipped: 0, errors: 0)
    service = instance_double(Jobs::LandedCommitsBackfill, call: service_result)
    retry_service = instance_double(Jobs::LandedCommitsBackfill, call: retry_result)
    allow(Jobs::LandedCommitsBackfill).to receive(:new).and_return(service, retry_service)

    described_class.new(task).call
    expect(task.reload).to have_attributes(state: "running", completed_units: 1, failed_units: 1)
    expect(task.checkpoint["unresolved_repositories"]).to contain_exactly(
      hash_including("id" => repository.id, "slug" => repository.slug, "errors" => 1)
    )

    expect { described_class.new(task).call }
      .to raise_error(MaintenanceTasks::Definitions::LandedCommitsBackfill::UnresolvedLandingsError)

    expect(task.reload).to have_attributes(
      state: "failed",
      completed_units: 1,
      failed_units: 1
    )
    expect(task.last_error).to include(repository.slug)
    expect(task.checkpoint["retry_unresolved_repository_ids"]).to eq([ repository.id ])

    task.update!(state: "running", last_error: nil)
    described_class.new(task).call

    expect(task.reload).to have_attributes(state: "running", completed_units: 2, failed_units: 1)
    expect(task.checkpoint["retry_unresolved_repository_ids"]).to be_empty
    expect(task.checkpoint["unresolved_repositories"]).to be_empty
  end
end
