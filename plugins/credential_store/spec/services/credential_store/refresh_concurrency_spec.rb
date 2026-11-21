require "rails_helper"

RSpec.describe "Credential Store refresh concurrency" do
  self.use_transactional_tests = false

  before do
    skip "MySQL row locking is required" unless ActiveRecord::Base.connection.adapter_name == "Mysql2"

    @user = Factories.user
    @credential = CredentialStore::Credential.create!(
      name: "OAuth payload",
      credential_type: "k8s_cluster.kubeconfig",
      scope_type: "user",
      scope_id: @user.id,
      created_by: @user,
      owner_user: @user,
      payload: "0"
    )
  end

  after do
    next unless @credential

    @credential.access_events.delete_all
    @credential.update_columns(revoked_at: Time.current)
    @user.destroy!
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "serializes concurrent refresh callbacks against the latest payload" do
    first_entered = Queue.new
    release_first = Queue.new
    results = Queue.new

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CredentialStore::Broker.refresh_credential!(credential: @credential.id, plugin_name: "k8s_cluster", purpose: "refresh") do |payload|
          first_entered << true
          release_first.pop
          (payload.to_i + 1).to_s
        end
      end
    rescue StandardError => e
      results << e
    end
    first_entered.pop

    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        CredentialStore::Broker.refresh_credential!(credential: @credential.id, plugin_name: "k8s_cluster", purpose: "refresh") do |payload|
          (payload.to_i + 1).to_s
        end
      end
    rescue StandardError => e
      results << e
    end

    expect(second.join(0.1)).to be_nil
    release_first << true
    first.join
    second.join

    errors = []
    errors << results.pop until results.empty?
    expect(errors).to be_empty
    expect(@credential.reload.payload).to eq("2")
    expect(@credential.access_events.where(action: "refresh").count).to eq(2)
  ensure
    release_first << true if first&.alive?
    first&.join
    second&.join
  end
end
