require "rails_helper"

RSpec.describe ChatTemplates::Postmortem do
  it "renders the Job-failure analyst system addendum and first user prompt" do
    repo = repository
    job = Factories.job(repository: repo, issue_number: 123, issue_title: "Flames from the queue")
    job.latest_workflow.update!(state: "failed", finished_at: Time.current)

    template = described_class.new(job: job).render

    expect(template.title).to eq("Postmortem Job ##{job.id}")
    expect(template.system_prompt).to include("act as a Job-failure analyst")
    expect(template.system_prompt).to include("read_job, list_jobs, read_pr")
    expect(template.system_prompt).to include("Cite specific transcript")
    expect(template.user_message).to eq(
      "Postmortem Job ##{job.id}: Flames from the queue. Why did this fail? Cite specific transcript lines and code."
    )
  end
end
