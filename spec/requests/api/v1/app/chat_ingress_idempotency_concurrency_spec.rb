require "rails_helper"

RSpec.describe "Chat ingress idempotency concurrency", type: :request do
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  before do
    clear_enqueued_jobs
    @user = Factories.user(claude_oauth_token: "oat-test")
    @chat = ChatSession.create!(user: @user)
  end

  after do
    ChatSession.where(id: @chat.id).destroy_all
    User.where(id: @user.id).destroy_all
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "allows exactly one concurrent request to create effects for a key" do
    sessions = Array.new(2) do
      ActionDispatch::Integration::Session.new(Rails.application).tap do |session|
        session.post("/session", params: { email_address: @user.email_address, password: "supersecret" })
        expect(session.response).to have_http_status(:redirect)
      end
    end
    key = SecureRandom.uuid
    ready = Queue.new
    start = Queue.new

    threads = sessions.map do |session|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          session.post(
            "/api/v1/app/chats/#{@chat.id}/message",
            params: { client_idempotency_key: key, chat_message: { text: "Create once" } }
          )
          [ session.response.status, session.response.parsed_body ]
        end
      end
    end
    sessions.size.times { ready.pop }
    sessions.size.times { start << true }
    results = threads.map(&:value)

    expect(results.map(&:first)).to eq([ 200, 200 ])
    expect(results.map(&:second).uniq.one?).to be(true)
    expect(@chat.messages.where(client_idempotency_key: key).count).to eq(1)
    expect(ChatIngressReceipt.where(sender_user: @user, idempotency_key: key).count).to eq(1)
    expect(enqueued_jobs.count { |job| job.fetch(:job) == ChatTurnJob }).to eq(1)
  end
end
