require "rails_helper"

RSpec.describe Signups::Creator, "concurrency" do
  self.use_transactional_tests = false

  before { clear_signup_records! }

  after do
    clear_signup_records!
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "allows only one concurrent signup to consume an invitation" do
    admin = Factories.user
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com")

    results = create_concurrently([
      { email_address: "one@example.com", password: "supersecret" },
      { email_address: "two@example.com", password: "supersecret" }
    ], invitation:)

    expect(results.count(&:created?)).to eq(1)
    expect(results.count(&:forbidden?)).to eq(1)
    expect(invitation.reload).to be_accepted
  end

  it "allows only one concurrent first signup" do
    results = create_concurrently([
      { email_address: "one@example.com", password: "supersecret" },
      { email_address: "two@example.com", password: "supersecret" }
    ])

    expect(results.count(&:created?)).to eq(1)
    expect(results.count(&:forbidden?)).to eq(1)
    expect(User.count).to eq(1)
  end

  def create_concurrently(attribute_sets, invitation: nil)
    errors = Queue.new
    results = Queue.new
    ready = Queue.new
    start = Queue.new

    threads = attribute_sets.map do |attributes|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          current_invitation = Invitation.find(invitation.id) if invitation
          results << described_class.call(attributes:, invitation: current_invitation)
        rescue StandardError => error
          errors << error
        end
      end
    end

    attribute_sets.size.times { ready.pop }
    attribute_sets.size.times { start << true }
    threads.each(&:join)

    raise errors.pop unless errors.empty?

    Array.new(attribute_sets.size) { results.pop }
  end

  def clear_signup_records!
    Invitation.delete_all
    User.destroy_all
    BootstrapLock.delete_all
  end
end
