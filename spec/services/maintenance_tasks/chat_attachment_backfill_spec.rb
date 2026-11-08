require "rails_helper"

RSpec.describe MaintenanceTasks::Definitions::ChatAttachmentBackfill do
  let(:definition) { described_class.new }
  let(:chat) { ChatSession.create!(user: Factories.user) }

  it "reports dry-run units for messages, queued messages, and scratchpad items" do
    create_inline_records

    expect(definition.estimate_total_units).to eq(3)
    expect(definition.pending_reason).to eq("3 chat record(s) contain legacy inline attachment data.")
  end

  it "is batched, resumable, idempotent, and retries a partial failure" do
    good = create_legacy_message(inline_content("good.txt", Base64.strict_encode64("good")))
    bad = chat.queued_messages.create!(content: inline_content("bad.txt", "%%%"))
    task = build_task

    first_result = run_until_done(task)

    expect(first_result).to have_attributes(done: true, failed: 1)
    expect(good.reload.content.dig("attachments", 0, "data")).to be_nil
    expect(bad.reload.content.dig("attachments", 0, "data")).to(
      eq("%%%").and(be_present)
    )
    expect(ChatFileAttachment.count).to eq(1)
    expect(task.checkpoint.fetch("unresolved")).to contain_exactly(
      include("source" => "queued_messages", "id" => bad.id, "error" => match(/malformed base64/))
    )

    bad.update!(content: inline_content("bad.txt", Base64.strict_encode64("fixed")))
    retry_result = run_until_done(task)

    expect(retry_result).to have_attributes(done: true, failed: 0)
    expect(bad.reload.content.dig("attachments", 0, "data")).to be_nil
    expect(ChatFileAttachment.count).to eq(2)
    expect { run_until_done(task) }.not_to change(ChatFileAttachment, :count)
  end

  private

  def create_inline_records
    encoded = Base64.strict_encode64("bytes")
    create_legacy_message(inline_content("message.txt", encoded))
    chat.queued_messages.create!(content: inline_content("queue.txt", encoded))
    chat.scratchpad_items.create!(content: JSON.generate(inline_content("draft.txt", encoded)), position: 0)
  end

  def inline_content(name, data)
    { "text" => "Attachment", "attachments" => [ { "name" => name, "mime_type" => "text/plain", "data" => data } ] }
  end

  def create_legacy_message(content)
    chat.messages.build(role: "user", content: content).tap { |message| message.save!(validate: false) }
  end

  def build_task
    attributes = definition.build_task_attributes(
      trigger_kind: "spec",
      trigger_key: definition.key,
      task_key: "spec:#{definition.key}:#{SecureRandom.hex(3)}"
    )
    MaintenanceTask.new(attributes.merge(state: "running"))
  end

  def run_until_done(task)
    20.times do
      result = definition.perform_batch(task)
      return result if result.done
    end
    raise "backfill did not finish"
  end
end
