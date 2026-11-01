require "rails_helper"

RSpec.describe PendingActionTransition, :ci_only do
  self.use_transactional_tests = false

  after do
    User.where(email_address: "pending-action-transition-race@example.com").destroy_all
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "serializes transition sequences for concurrent item decisions" do
    user = User.create!(email_address: "pending-action-transition-race@example.com", password: "supersecret")
    request = ChatPendingAction.create!(
      request_kind: "authorization_request",
      user: user,
      origin: user,
      subject: user,
      deduplication_key: "transition-race"
    )
    item_ids = 2.times.map do |index|
      request.authorization_items.create!(
        kind: "operation",
        capability: "mysql.data",
        operation: "write",
        operation_version: 1,
        resource_type: "mysql_connection",
        invocation_fingerprint: "sha256:#{index}"
      ).id
    end

    errors = Queue.new
    ready = Queue.new
    start = Queue.new
    threads = item_ids.map do |item_id|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          PendingActionItem.find(item_id).decide!("approved", principal: user, duration: "invocation")
        rescue StandardError => error
          errors << error
        end
      end
    end

    threads.size.times { ready.pop }
    threads.size.times { start << true }
    threads.each(&:join)
    raise errors.pop unless errors.empty?

    sequences = request.transitions.order(:sequence).pluck(:sequence)
    expect(sequences).to eq((1..sequences.size).to_a)
    expect(request.transitions.where(event_type: "state_changed").count).to eq(2)
  end
end
