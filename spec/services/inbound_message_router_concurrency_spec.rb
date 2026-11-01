require "rails_helper"

RSpec.describe "Inbound message router concurrency" do
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  before do
    clear_enqueued_jobs
    @user = Factories.user
    @identity = Factories.platform_identity(user: @user, platform: "telegram", external_id: "concurrent-sender")
  end

  after do
    ChatIngressReceipt.where(sender_user: @user).destroy_all
    ChatSession.where(user: @user).destroy_all
    @identity.destroy!
    @user.destroy!
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "creates and triggers exactly one message for concurrent duplicate delivery" do
    ready = Queue.new
    start = Queue.new
    session_lookups = Queue.new
    allow(ChatSession).to receive(:for_platform).and_wrap_original do |original, **arguments|
      session_lookups << true
      original.call(**arguments)
    end
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          InboundMessageRouter.new(
            platform: "telegram",
            external_id: @identity.external_id,
            external_handle: "alice",
            message_text: "Only once",
            native_message_id: "update-9",
            conversation_id: "dm-concurrent"
          ).call
        end
      end
    end
    threads.size.times { ready.pop }
    threads.size.times { start << true }
    results = threads.map(&:value)

    expect(session_lookups.size).to eq(1)
    expect(results.map(&:session).map(&:id).uniq.one?).to be(true)
    expect(ChatMessage.where(sender_user: @user, content: { "text" => "Only once" }).count).to eq(1)
    expect(enqueued_jobs.count { |job| job.fetch(:job) == ChatTurnJob }).to eq(1)
  end
end
