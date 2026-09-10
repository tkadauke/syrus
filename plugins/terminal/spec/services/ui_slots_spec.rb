require "rails_helper"

RSpec.describe Terminal::UiSlots do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job(user: user, repository: repo, issue_title: "Build terminal UI") }
  let(:workflow) { job.workflows.first }

  it "includes backend workflow workspace availability in the workflow action slot props" do
    workflow.update!(cleaned_up_at: Time.current)

    panels = described_class.ui_slots(slot: "job.workflow.actions", context: { job: job, user: user })
    availability = panels.first.dig(:props, :availability_by_workflow_id, workflow.id)

    expect(availability).to include(
      available: false,
      reason: "This workflow workspace has been cleaned up.",
      working_directory: WorkflowWorkspace.path_for(workflow).to_s
    )
  end
end
