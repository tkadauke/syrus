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

  it "serializes issuance with authority revocation" do
    user = User.create!(email_address: "authorized-invocation-race@example.com", password: "supersecret")
    request = ChatPendingAction.create!(request_kind: "authorization_request", user:, origin: user,
      subject: user, deduplication_key: "authorized-invocation-revocation-race")
    item = request.authorization_items.create!(kind: "operation", capability: "mysql.data", operation: "write",
      operation_version: 1, resource_type: "mysql_connection", invocation_fingerprint: "sha256:revoke-race")
    item.decide!("approved", principal: user, duration: "invocation")
    lease = PermissionLease.create!(
      owner_user: user, subject_selector_type: "workflow_role", subject_selector_id: "implementer",
      capability: "mysql.data", operation: "write", resource_type: "mysql_connection",
      resource_scope: {}, constraints: {}, effects: [], duration_kind: "invocation",
      invocation_fingerprint: "sha256:revoke-race", max_uses: 1, issued_by_user: user
    )

    create_started = Queue.new
    finish_create = Queue.new
    original_create = described_class.method(:create!)
    allow(described_class).to receive(:create!) do |attributes|
      create_started << true
      finish_create.pop
      original_create.call(attributes)
    end

    issued = Queue.new
    issuer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        issued << described_class.issue!(pending_action_item: item, authority: lease, tool_name: "mysql_write")
      end
    end
    create_started.pop
    revoker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        PermissionLease.find(lease.id).revoke!(actor: user)
      end
    end
    finish_create << true
    [ issuer, revoker ].each(&:join)

    expect(issued.pop.reload).to be_invalidated
  end

  it "serializes claim revalidation with authority revocation" do
    suffix = SecureRandom.hex(6)
    user = User.create!(email_address: "authorized-invocation-claim-revocation-race-#{suffix}@example.com", password: "supersecret")
    request = ChatPendingAction.create!(request_kind: "authorization_request", user:, origin: user,
      subject: user, deduplication_key: "authorized-invocation-claim-revocation-race-#{suffix}")
    item = request.authorization_items.create!(kind: "operation", capability: "mysql.data", operation: "write",
      operation_version: 1, resource_type: "mysql_connection", invocation_fingerprint: "sha256:claim-revoke-race")
    item.decide!("approved", principal: user, duration: "invocation")
    lease = PermissionLease.create!(
      owner_user: user, subject_selector_type: "workflow_role", subject_selector_id: "implementer",
      capability: "mysql.data", operation: "write", resource_type: "mysql_connection",
      resource_scope: {}, constraints: {}, effects: [], duration_kind: "invocation",
      invocation_fingerprint: "sha256:claim-revoke-race", max_uses: 1, issued_by_user: user
    )
    invocation = described_class.issue!(pending_action_item: item, authority: lease, tool_name: "mysql_write")

    revalidation_started = Queue.new
    finish_revalidation = Queue.new
    claim_result = Queue.new
    expect(lease).to receive(:with_lock).and_call_original
    claimant = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        claim_result << invocation.claim!(fingerprint: "sha256:claim-revoke-race", claimant: user,
          claim_key: "claim-revoke-race-#{suffix}", origin_resumable: ->(_) { true },
          revalidate: ->(_) do
            revalidation_started << true
            finish_revalidation.pop
            true
          end)
      end
    end
    revalidation_started.pop

    revoked = Queue.new
    revoker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        PermissionLease.find(lease.id).revoke!(actor: user)
        revoked << true
      end
    end

    expect { revoked.pop(true) }.to raise_error(ThreadError)
    finish_revalidation << true
    [ claimant, revoker ].each(&:join)

    expect(claim_result.pop).to be_claimed
    expect(revoked.pop).to be(true)
    expect(invocation.reload).to be_claimed
    expect(lease.reload).to be_revoked_at
  end
end
