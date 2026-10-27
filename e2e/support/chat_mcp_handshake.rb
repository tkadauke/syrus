require "json"
require "net/http"
require "open3"
require "timeout"
require "uri"

module ChatMcpHandshake
  PROTOCOL_VERSION = "2024-11-05"
  TIMEOUT = 20

  class Error < StandardError; end

  class Transport
    def initialize(config)
      @config = config.deep_symbolize_keys
    end

    def self.for(config)
      { "stdio" => Stdio, "http" => Http }.fetch(config.fetch(:type).to_s).new(config)
    end

    private

    attr_reader :config

    def requests
      [
        { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: "syrus-e2e", version: "1" } } },
        { jsonrpc: "2.0", method: "notifications/initialized" },
        { jsonrpc: "2.0", id: 2, method: "tools/list" }
      ]
    end

    def validate!(responses)
      initialize_response = responses.find { |response| response["id"] == 1 }
      tools_response = responses.find { |response| response["id"] == 2 }
      raise Error, "initialize did not return a result" unless initialize_response&.key?("result")

      tools = tools_response&.dig("result", "tools")
      unless tools.is_a?(Array) && tools.any?
        raise Error, "tools/list did not return any tools: #{JSON.generate(tools_response)}"
      end

      tools.length
    end
  end

  class Stdio < Transport
    def call
      stdout = stderr = status = nil
      Timeout.timeout(TIMEOUT) do
        stdout, stderr, status = Open3.capture3(
          config.fetch(:env, {}).transform_keys(&:to_s),
          config.fetch(:command),
          *Array(config[:args]),
          stdin_data: requests.map(&:to_json).join("\n") + "\n",
          unsetenv_others: true
        )
      end
      raise Error, "server exited #{status.exitstatus}: #{stderr}" unless status.success?

      lines = stdout.lines.map(&:chomp)
      raise Error, "server emitted a blank JSON-RPC frame" if lines.any?(&:empty?)

      validate!(lines.map { |line| JSON.parse(line) })
    rescue Timeout::Error
      raise Error, "server did not complete the MCP handshake within #{TIMEOUT}s"
    rescue JSON::ParserError => e
      raise Error, "server emitted invalid JSON-RPC: #{e.message}"
    end
  end

  class Http < Transport
    def call
      uri = URI(config.fetch(:url))
      responses = requests.filter_map do |payload|
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json, text/event-stream"
        request["Mcp-Session-Id"] = @session_id if @session_id
        config.fetch(:headers, {}).each { |key, value| request[key.to_s] = value.to_s }
        request.body = payload.to_json
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: TIMEOUT) { |http| http.request(request) }
        raise Error, "HTTP MCP server returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
        @session_id ||= response["Mcp-Session-Id"]
        next if response.body.to_s.empty?

        parse_response(response)
      end
      validate!(responses)
    rescue JSON::ParserError => e
      raise Error, "HTTP MCP server emitted invalid JSON-RPC: #{e.message}"
    end

    private

    def parse_response(response)
      return JSON.parse(response.body) unless response["Content-Type"].to_s.start_with?("text/event-stream")

      data = response.body.lines.filter_map do |line|
        line.delete_prefix("data:").strip if line.start_with?("data:")
      end.join("\n")
      JSON.parse(data)
    end
  end

  module_function

  def call
    user = User.find_by!(email_address: "demo@syrus.local")
    original_provider = user.chat_provider
    provider_plugin_names = Syrus::PluginRegistry.all_plugins.filter_map do |manifest|
      manifest.name if manifest.provides.key?(:chat_provider)
    end
    provider_plugin_states = PluginRecord.where(name: provider_plugin_names).pluck(:name, :enabled, :ever_enabled).to_h do |name, enabled, ever_enabled|
      [ name, [ enabled, ever_enabled ] ]
    end
    PluginRecord.where(name: provider_plugin_names).update_all(enabled: true, ever_enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    persistent_feature = Feature.find_by!(slug: "persistent_mcp_sidecar")
    persistent_feature_was_enabled = persistent_feature.enabled?
    persistent_feature.update!(enabled: true)
    Feature.clear_enabled_cache!
    results = { persistent: handshakes_for_all_providers(user) }

    persistent_feature.update!(enabled: false)
    Feature.clear_enabled_cache!
    results[:fallback] = handshakes_for_all_providers(user)

    puts "CHAT_MCP_HANDSHAKE=#{JSON.generate(results)}"
  ensure
    user&.update_columns(chat_provider: original_provider) if user&.persisted?
    provider_plugin_states&.each do |name, (enabled, ever_enabled)|
      PluginRecord.where(name: name).update_all(enabled: enabled, ever_enabled: ever_enabled)
    end
    Syrus::PluginRegistry.clear_plugin_record_cache!
    persistent_feature&.update!(enabled: persistent_feature_was_enabled)
    Feature.clear_enabled_cache!
    ChatMcpStdioFallback.reset_for_test!
    stop_persistent_daemon!
  end

  def handshakes_for_all_providers(user)
    results = {}

    User.chat_providers.each do |provider_name|
      chat = ChatSession.create!(user: user, repository: user.repositories.first, chat_provider: provider_name)
      message = chat.messages.create!(role: "user", content: { text: "MCP handshake guard" })
      job = ChatTurnJob.new
      job.instance_variable_set(:@chat, chat)
      job.instance_variable_set(:@user_message, message)
      provider = ChatProviders.for(provider_name).new(chat: chat)
      decision = job.send(:chat_mcp_transport_decision, provider)
      servers = job.send(:chat_mcp_servers, decision)

      results[provider_name] = servers.to_h do |name, config|
        tool_count = Transport.for(config).call
        [ name, { transport: config.fetch(:type), tools: tool_count } ]
      rescue Error => e
        raise Error, "#{provider_name}/#{name}: #{e.message}"
      end
    ensure
      chat&.destroy!
    end

    raise Error, "no chat providers were registered" if results.empty?

    results
  end

  def stop_persistent_daemon!
    daemon = PersistentMcpDaemon.instance_variable_get(:@instance)
    daemon&.stop
    PersistentMcpDaemon.instance_variable_set(:@instance, nil)
  end
end

ChatMcpHandshake.call
