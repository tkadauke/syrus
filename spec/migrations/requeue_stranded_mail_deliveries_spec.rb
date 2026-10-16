require "rails_helper"
require Rails.root.join("db/queue_migrate/20261015065603_requeue_stranded_mail_deliveries")

RSpec.describe RequeueStrandedMailDeliveries do
  subject(:migration) { described_class.new }

  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before { clear_solid_queue_test_tables! }

  it "moves stranded mail jobs and their executions onto the consumed queue" do
    ready_mail = create_queue_job(class_name: "ActionMailer::MailDeliveryJob", queue_name: "mailers")
    scheduled_mail = create_queue_job(class_name: "ActionMailer::MailDeliveryJob", queue_name: "mailers")
    unrelated = create_queue_job(class_name: "OtherJob", queue_name: "mailers")
    scheduled_mail.update!(scheduled_at: 1.hour.from_now)

    SolidQueue::ReadyExecution.create!(job: ready_mail, queue_name: "mailers", priority: 0)
    SolidQueue::ScheduledExecution.create!(
      job: scheduled_mail,
      queue_name: "mailers",
      priority: 0
    )
    SolidQueue::ReadyExecution.create!(job: unrelated, queue_name: "mailers", priority: 0)

    migration.migrate(:up)

    expect(ready_mail.reload.queue_name).to eq("control_plane")
    expect(ready_mail.ready_execution.reload.queue_name).to eq("control_plane")
    expect(scheduled_mail.reload.queue_name).to eq("control_plane")
    expect(scheduled_mail.scheduled_execution.reload.queue_name).to eq("control_plane")
    expect(unrelated.reload.queue_name).to eq("mailers")
    expect(unrelated.ready_execution.reload.queue_name).to eq("mailers")
  end

  it "is idempotent" do
    mail = create_queue_job(class_name: "ActionMailer::MailDeliveryJob", queue_name: "mailers")
    SolidQueue::ReadyExecution.create!(job: mail, queue_name: "mailers", priority: 0)

    2.times { migration.migrate(:up) }

    expect(mail.reload.queue_name).to eq("control_plane")
    expect(mail.ready_execution.reload.queue_name).to eq("control_plane")
  end

  private

  def create_queue_job(class_name:, queue_name:)
    SolidQueue::Job.create!(
      class_name: class_name,
      queue_name: queue_name,
      priority: 0,
      arguments: { "arguments" => [] }
    )
  end
end
