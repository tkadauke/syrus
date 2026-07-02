require "rails_helper"

RSpec.describe TerminalChannel, type: :channel do
  let(:user) { Factories.user }
  let(:relay_address) { "127.0.0.1:4444" }
  let(:socket) { double("relay socket", puts: nil, write: nil, close: nil) }

  before do
    stub_connection current_user: user
  end

  def enable_terminal
    Feature.create!(slug: "terminal", category: "labs", name: "Terminal", enabled: true)
  end

  def terminal_session(**attrs)
    TerminalSession.create!(
      {
        user: user,
        name: "scratch",
        working_directory: Rails.root.to_s,
        relay_address: relay_address,
        auth_token: "terminal-token",
        started_at: Time.current
      }.merge(attrs)
    )
  end

  def subscribe_without_reader(session)
    allow(TCPSocket).to receive(:new).and_return(socket)
    allow_any_instance_of(described_class).to receive(:stream_from_relay)

    subscribe(session_id: session.id)
  end

  it "rejects subscriptions when the terminal feature is disabled" do
    session = terminal_session

    subscribe(session_id: session.id)

    expect(subscription).to be_rejected
  end

  it "rejects subscriptions for missing sessions" do
    enable_terminal

    subscribe(session_id: 12_345)

    expect(subscription).to be_rejected
  end

  it "rejects subscriptions for sessions owned by another user" do
    enable_terminal
    session = terminal_session(user: Factories.user)

    subscribe(session_id: session.id)

    expect(subscription).to be_rejected
  end

  it "rejects subscriptions for finished sessions" do
    enable_terminal
    session = terminal_session(finished_at: Time.current, outcome: "exited")

    subscribe(session_id: session.id)

    expect(subscription).to be_rejected
  end

  it "polls until the relay address is ready before connecting" do
    enable_terminal
    session = terminal_session(relay_address: nil)

    allow_any_instance_of(described_class).to receive(:sleep) do
      session.update!(relay_address: relay_address)
    end
    allow(TCPSocket).to receive(:new).and_return(socket)
    allow_any_instance_of(described_class).to receive(:stream_from_relay)

    subscribe(session_id: session.id)

    expect(subscription).to be_confirmed
    expect(TCPSocket).to have_received(:new).with("127.0.0.1", 4444)
  end

  it "rejects when the relay address is not ready before the timeout" do
    enable_terminal
    session = terminal_session(relay_address: nil)
    stub_const("#{described_class}::RELAY_ADDRESS_TIMEOUT", 0.seconds)

    subscribe(session_id: session.id)

    expect(subscription).to be_rejected
  end

  it "sends the auth token to the relay after connecting" do
    enable_terminal
    session = terminal_session

    subscribe_without_reader(session)

    expect(subscription).to be_confirmed
    expect(socket).to have_received(:puts).with({ token: "terminal-token" }.to_json)
  end

  it "forwards browser messages as newline-delimited JSON frames" do
    enable_terminal
    session = terminal_session
    subscribe_without_reader(session)

    perform :receive, { "type" => "input", "data" => "ls\n" }
    perform :receive, { "type" => "resize", "cols" => 120, "rows" => 40 }

    expect(socket).to have_received(:write).with({ "type" => "input", "data" => "ls\n" }.to_json + "\n")
    expect(socket).to have_received(:write).with({ "type" => "resize", "cols" => 120, "rows" => 40 }.to_json + "\n")
  end

  it "transmits a disconnect frame when forwarding to the relay fails" do
    enable_terminal
    session = terminal_session
    allow(socket).to receive(:write).and_raise(Errno::EPIPE)
    subscribe_without_reader(session)

    perform :receive, { "type" => "input", "data" => "ls\n" }

    expect(transmissions).to include({ "type" => "disconnected" })
  end

  it "forwards output frames from the relay to the browser" do
    enable_terminal
    session = terminal_session
    reader_socket = double("reader socket", puts: nil, close: nil)

    frame = { type: "output", data: Base64.strict_encode64("hello\x00".b) }.to_json + "\n"
    reads = 0
    allow(reader_socket).to receive(:read_nonblock).with(4096) do
      reads += 1
      raise EOFError if reads > 1

      frame
    end
    allow(TCPSocket).to receive(:new).and_return(reader_socket)

    subscribe(session_id: session.id)
    subscription.instance_variable_get(:@relay_thread).join(1)

    expect(transmissions).to include(
      { "type" => "output", "data" => Base64.strict_encode64("hello\x00".b) },
      { "type" => "disconnected" }
    )
  end

  it "forwards replay frames from the relay to the browser" do
    enable_terminal
    session = terminal_session
    reader_socket = double("reader socket", puts: nil, close: nil)

    frame = { type: "replay", data: Base64.strict_encode64("scrollback".b) }.to_json + "\n"
    reads = 0
    allow(reader_socket).to receive(:read_nonblock).with(4096) do
      reads += 1
      raise EOFError if reads > 1

      frame
    end
    allow(TCPSocket).to receive(:new).and_return(reader_socket)

    subscribe(session_id: session.id)
    subscription.instance_variable_get(:@relay_thread).join(1)

    expect(transmissions).to include(
      { "type" => "replay", "data" => Base64.strict_encode64("scrollback".b) },
      { "type" => "disconnected" }
    )
  end

  it "closes the relay socket and kills the reader thread when unsubscribed" do
    enable_terminal
    session = terminal_session
    thread = instance_double(Thread, kill: nil)

    allow(TCPSocket).to receive(:new).and_return(socket)
    allow(Thread).to receive(:new).and_return(thread)

    subscribe(session_id: session.id)
    unsubscribe

    expect(socket).to have_received(:close)
    expect(thread).to have_received(:kill)
  end
end
