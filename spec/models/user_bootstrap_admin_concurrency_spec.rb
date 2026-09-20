require "rails_helper"

RSpec.describe "first-signup admin concurrency" do
  self.use_transactional_tests = false

  let(:attrs) { { email_address: "user@example.com", password: "supersecret" } }

  before { clear_user_records! }

  after do
    clear_user_records!
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "promotes exactly one concurrent first signup" do
    users = create_users_concurrently([
      attrs,
      attrs.merge(email_address: "two@example.com")
    ])

    expect(users.count(&:admin?)).to eq(1)
    expect(User.admin.count).to eq(1)
  end

  def create_users_concurrently(attribute_sets)
    errors = Queue.new
    users = Queue.new
    ready = Queue.new
    start = Queue.new

    threads = attribute_sets.map do |attributes|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          users << User.create!(attributes)
        rescue StandardError => e
          errors << e
        end
      end
    end

    attribute_sets.size.times { ready.pop }
    attribute_sets.size.times { start << true }
    threads.each(&:join)

    raise errors.pop unless errors.empty?

    Array.new(attribute_sets.size) { users.pop }
  end

  def clear_user_records!
    User.destroy_all
    BootstrapLock.delete_all
  end
end
