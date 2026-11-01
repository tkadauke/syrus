require "rails_helper"

RSpec.describe Permissions::ScheduledAuthorization, :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:job) { Factories.job_record(user:, repository:, kind: "cron", scheduled_task_id: 41, issue_number: nil) }
  let(:run) { Factories.run(job:, user:) }
  let(:context) { McpToolContext.from_run(run) }
  let(:descriptor) do
    Permissions::CapabilityDescriptorAdapter.for_registry_entry(
      tool_name: "write_external_record", capability: "records.write", mutation: true,
      required_roles: [ context.role ]
    )
  end
  let(:tool) do
    value = descriptor
    Class.new do
      def self.tool_name = "write_external_record"
    end.tap { |klass| klass.define_singleton_method(:capability_descriptor) { value } }
  end

  it "creates a checkpointed request and associates it with the scheduled Job" do
    result = described_class.route(tool:, context:, arguments: { record_id: 7 })

    expect(result).to be_created
    expect(result.request).to have_attributes(origin: run, checkpoint_state: "waiting")
    expect(job.reload.related_authorization_requests).to contain_exactly(result.request)
  end

  it "reuses an equivalent request for a later scheduled fire without checkpointing it" do
    first = described_class.route(tool:, context:, arguments: { record_id: 7 })
    later_job = Factories.job_record(user:, repository:, kind: "cron", scheduled_task_id: 41, issue_number: nil)
    later_run = Factories.run(job: later_job, user:)

    result = described_class.route(tool:, context: McpToolContext.from_run(later_run), arguments: { record_id: 7 })

    expect(result).to be_reused
    expect(result.request).to eq(first.request)
    expect(later_run.reload.authorization_requests).to be_empty
    expect(later_job.reload.related_authorization_requests).to contain_exactly(first.request)
  end

  it "does not reuse an equivalent request from another repository" do
    first = described_class.route(tool:, context:, arguments: { record_id: 7 })
    other_repository = Factories.repository(user:)
    other_job = Factories.job_record(user:, repository: other_repository, kind: "cron", scheduled_task_id: 41, issue_number: nil)
    other_run = Factories.run(job: other_job, user:)

    result = described_class.route(tool:, context: McpToolContext.from_run(other_run), arguments: { record_id: 7 })

    expect(result).to be_created
    expect(result.request).not_to eq(first.request)
    expect(result.request.repository).to eq(other_repository)
    expect(other_job.reload.related_authorization_requests).to contain_exactly(result.request)
  end

  it "blocks a scheduled invocation when policy denies it" do
    denied_descriptor = Permissions::CapabilityDescriptor.new(**descriptor.to_h.merge(defaults: { context.role => :deny }))
    allow(tool).to receive(:capability_descriptor).and_return(denied_descriptor)

    result = described_class.route(tool:, context:, arguments: { record_id: 7 })

    expect(result.status).to eq(:policy_denied)
    expect(result.request).to be_nil
    expect(ChatPendingAction.where(request_kind: "authorization_request")).to be_empty
  end
end
