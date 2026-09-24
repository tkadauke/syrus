require "rails_helper"

RSpec.describe "AppEvents.next_sequence concurrency" do
  self.use_transactional_tests = false

  after do
    User.where(email_address: "sequence-race@example.com").delete_all
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "never assigns the same sequence number to two events broadcast concurrently for the same user" do
    user = User.create!(email_address: "sequence-race@example.com", password: "supersecret")

    sequences = broadcast_concurrently(user, count: 8)

    expect(sequences.uniq.length).to eq(sequences.length)
    expect(sequences.sort).to eq((1..8).to_a)
  end

  def broadcast_concurrently(user, count:)
    errors = Queue.new
    results = Queue.new
    allow(AppUserChannel).to receive(:broadcast_to) do |_target, event|
      results << event.fetch("sequence")
    end

    ready = Queue.new
    start = Queue.new

    threads = Array.new(count) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          AppEvents.broadcast(user: user, type: "job.updated", resource: "job", id: i)
        rescue StandardError => e
          errors << e
        end
      end
    end

    count.times { ready.pop }
    count.times { start << true }
    threads.each(&:join)

    raise errors.pop unless errors.empty?

    Array.new(count) { results.pop }
  end
end
