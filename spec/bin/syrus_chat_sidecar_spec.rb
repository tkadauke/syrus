# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "rails_helper"

RSpec.describe "bin/syrus-chat-sidecar", :ci_only do
  self.use_transactional_tests = false

  let(:root) { Rails.root.to_s }
  let(:data_root) { Dir.mktmpdir("syrus-chat-sidecar-spec") }

  after do
    FileUtils.rm_rf(data_root)
    AppSetting.delete_all
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "boots both chat MCP sidecars from the generated config against a persisted chat session" do
    records = create_persisted_chat_session!
    config = generated_mcp_config_for(records.fetch(:chat), records.fetch(:message))

    essential = config.fetch("mcpServers").fetch("syrus-chat-sidecar")
    deferred = config.fetch("mcpServers").fetch("syrus-chat-deferred-sidecar")

    expect(essential.fetch("command")).to eq(Rails.root.join("bin/syrus-chat-sidecar").to_s)
    expect(deferred.fetch("command")).to eq(Rails.root.join("bin/syrus-chat-deferred-sidecar").to_s)
    expect(essential.fetch("env")).to include("PATH" => ENV.fetch("PATH"))
    expect(deferred.fetch("env")).to include("PATH" => ENV.fetch("PATH"))

    essential_tools = list_tools_via_stdio(essential)
    deferred_tools = list_tools_via_stdio(deferred)

    expect(essential_tools).to include("propose_job", "list_proposals", "repo_info")
    expect(essential_tools).not_to include("read_chat_messages")
    expect(deferred_tools).to include("read_chat_messages", "read_workflow")
    expect(deferred_tools).not_to include("propose_job")
  ensure
    cleanup_records(records) if records
  end

  private

  def create_persisted_chat_session!
    user = Factories.user
    repository = Factories.repository(user: user)
    chat = ChatSession.create!(user: user, repository: repository, title: "Sidecar E2E")
    message = chat.messages.create!(role: "user", content: "List available tools")

    { user: user, repository: repository, chat: chat, message: message }
  end

  def generated_mcp_config_for(chat, message)
    with_env("SYRUS_DATA_ROOT" => data_root) do
      job = ChatTurnJob.new
      job.instance_variable_set(:@chat, chat)
      job.instance_variable_set(:@user_message, message)
      job.send(:with_chat_mcp_config) do |path|
        JSON.parse(File.read(path))
      end
    end
  end

  def list_tools_via_stdio(server_config)
    with_sidecar_process(server_config) do |stdin, stdout|
      send_jsonrpc(stdin, stdout, "initialize", id: 1, params: {
        protocolVersion: "2025-06-18",
        clientInfo: { name: "syrus-spec", version: "1" }
      })

      response = send_jsonrpc(stdin, stdout, "tools/list", id: 2)
      response.fetch("result").fetch("tools").map { |tool| tool.fetch("name") }
    end
  end

  def with_sidecar_process(server_config)
    env = server_config.fetch("env").merge("SYRUS_DATA_ROOT" => data_root)
    args = Array(server_config["args"])
    stderr_text = +""

    Open3.popen3(env, server_config.fetch("command"), *args, chdir: root, unsetenv_others: true) do |stdin, stdout, stderr, wait_thread|
      stderr_reader = Thread.new do
        stderr.read.to_s
      rescue IOError
        ""
      end

      begin
        result = yield stdin, stdout
        stdin.close unless stdin.closed?
        status = wait_for_exit(wait_thread)
        stderr_text = stderr_reader.value.to_s
        expect(status).to be_success, stderr_text
        result
      rescue Exception
        kill_process(wait_thread)
        stderr_text = stderr_reader.value.to_s
        raise
      ensure
        stdin.close unless stdin.closed?
        stdout.close unless stdout.closed?
        stderr.close unless stderr.closed?
      end
    end
  end

  def send_jsonrpc(stdin, stdout, method, id:, params: {})
    stdin.puts({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    stdin.flush

    # 30s allows for a cold Rails boot (~12s in test) before the sidecar can
    # start processing messages. Subsequent requests are fast once Rails is up.
    Timeout.timeout(30) do
      loop do
        line = stdout.gets
        raise "sidecar closed stdout while waiting for #{method}" if line.nil?

        response = JSON.parse(line)
        return response if response["id"] == id
      end
    end
  end

  def wait_for_exit(wait_thread)
    Timeout.timeout(10) { wait_thread.value }
  rescue Timeout::Error
    kill_process(wait_thread)
    wait_thread.value
  end

  def kill_process(wait_thread)
    Process.kill("TERM", wait_thread.pid)
  rescue Errno::ESRCH
    nil
  end

  def cleanup_records(records)
    records.fetch(:chat).destroy! if records[:chat]&.persisted?
    records.fetch(:repository).destroy! if records[:repository]&.persisted?
    records.fetch(:user).destroy! if records[:user]&.persisted?
  end

  def with_env(values)
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
