require "rails_helper"

RSpec.describe AuthorizedInvocation, :ci_only do
  self.use_transactional_tests = false

  after do
    User.where(email_address: "authorized-invocation-race@example.com").destroy_all
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "allows only one concurrent approver dispatch to claim a token" do
    user = User.create!(email_address: "authorized-invocation-race@example.com", password: "supersecret")
    request = ChatPendingAction.create!(request_kind: "authorization_request", user:, origin: user,
      subject: user, deduplication_key: "authorized-invocation-race")
    item = request.authorization_items.create!(kind: "operation", capability: "mysql.data", operation: "write",
      operation_version: 1, resource_type: "mysql_connection", invocation_fingerprint: "sha256:race")
    item.decide!("approved", principal: user, duration: "invocation")
    invocation = described_class.issue!(pending_action_item: item, tool_name: "mysql_write")

    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          claim = described_class.find(invocation.id)
          results << claim.claim!(fingerprint: "sha256:race", claimant: user,
            claim_key: "approver-#{index}", revalidate: ->(_) { true }, origin_resumable: ->(_) { true }).status
        end
      end
    end

    threads.size.times { ready.pop }
    threads.size.times { start << true }
    threads.each(&:join)

    expect(2.times.map { results.pop }).to contain_exactly(:claimed, :unavailable)
    expect(invocation.reload).to be_claimed
  end
end
