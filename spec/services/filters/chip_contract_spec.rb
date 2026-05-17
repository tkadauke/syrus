require "rails_helper"

RSpec.describe "Filters chip contract" do
  JOB_SPECIFIC_FIELDS = %w[
    state kind priority closure_reason triaging_reason validity pr_present
    pr_mergeable pr_number pr_title branch_name issue_number title description
    epic_id parent_job_id has_active_run has_unread_feedback has_child_jobs
    has_parent_job has_blocked_deps pinned_by_me latest_workflow_state
    latest_workflow_trigger_kind latest_run_state last_seen_comment_at finished_at
    age agent_provider tags attention
  ].freeze

  GENERIC_FIELDS = %w[
    created_at updated_at repository_id
  ].freeze

  it "keeps every registered job chip on the chip DSL contract" do
    Filters::Registry.for(:job).each do |field, class_name|
      chip = class_name.constantize

      expect(chip.filter_name).to eq(field)
      expect(chip.bucket).to be_present
      expect(chip.operators).to be_present
      expect(chip.instance_method(:apply).owner).not_to eq(Filters::Chips::Base)
    end
  end

  it "moves job-specific chips into the Jobs namespace" do
    JOB_SPECIFIC_FIELDS.each do |field|
      expect(Filters::Registry.find(field).name).to start_with("Filters::Chips::Jobs::")
    end
  end

  it "keeps generic chips at the top level" do
    GENERIC_FIELDS.each do |field|
      expect(Filters::Registry.find(field).name).to start_with("Filters::Chips::")
      expect(Filters::Registry.find(field).name).not_to start_with("Filters::Chips::Jobs::")
    end
  end
end
