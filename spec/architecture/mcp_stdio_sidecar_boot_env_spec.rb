# frozen_string_literal: true

require "rails_helper"

# A stdio MCP sidecar is a full Rails process, spawned as a child of the agent
# CLI. It therefore inherits whatever environment the agent config hands it --
# and `AgentSidecarEnvironment.build` deliberately strips the secrets Rails
# needs to boot (SECRET_KEY_BASE, the database password, the master key), so
# that agent-controlled code cannot read them.
#
# That scrubbing is deliberate and is asserted directly elsewhere: the chat MCP
# config is a JSON file the agent reads, so secrets written into it are secrets
# handed to the agent (see spec/jobs/chat_turn_job_spec.rb, which requires the
# chat sidecar env to contain none of them).
#
# But a sidecar that boots Rails still needs those secrets to start. So pairing
# a Rails-booting command with a scrubbed environment is unsatisfiable: the
# process dies on startup and the agent turn silently runs with zero MCP tools.
#
# The resolution is NOT to put the secrets back. Chat stdio fallback points the
# agent at the secret-free bin/syrus-mcp-proxy, which bridges to a worker-owned
# daemon started outside the agent-visible environment.
#
# This spec asserts the pairing rule directly, because the failure is invisible
# in development and test: SQLite needs no password and `config/master.key`
# supplies the master key from disk, so a scrubbed sidecar boots here and dies
# only on a deployment that supplies its secrets through the environment.
RSpec.describe "stdio MCP sidecar boot environment" do
  # The keys a Rails process cannot boot without when they are supplied through
  # the environment rather than from disk. All three are in
  # AgentSidecarEnvironment::SECRET_ENV_KEYS, i.e. `.build` removes them.
  REQUIRED_BOOT_SECRETS = %w[SECRET_KEY_BASE SYRUS_DATABASE_PASSWORD RAILS_MASTER_KEY].freeze

  after do
    ChatMcpStdioFallback.reset_for_test!
  end

  # Populate the secrets in the real ENV so the builders have something to
  # forward. Without this the assertion is vacuous: `.build_boot` would also
  # return an env with no secrets in it, simply because there were none to pass.
  def with_boot_secrets_in_env
    saved = REQUIRED_BOOT_SECRETS.to_h { |key| [ key, ENV[key] ] }
    REQUIRED_BOOT_SECRETS.each { |key| ENV[key] = "spec-#{key.downcase}" }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # True when the command is a Rails process, i.e. it will need the boot
  # secrets. Read from the script itself rather than hardcoding a list, so a new
  # sidecar entrypoint is classified correctly without editing this spec.
  #
  # Follows `exec` into a sibling binstub, because the deferred chat sidecar is a
  # seven-line wrapper that execs the essential one -- it boots Rails without
  # containing the require itself.
  def boots_rails?(command, seen: [])
    path = command.to_s
    return false unless File.file?(path)
    return false if seen.include?(path)

    source = File.read(path)
    return true if source.include?("config/environment")

    source.scan(/File\.expand_path\(\s*["']([^"']+)["']\s*,\s*__dir__\s*\)/).flatten.any? do |sibling|
      boots_rails?(File.join(File.dirname(path), sibling), seen: seen + [ path ])
    end
  end

  def stdio_configs
    user = Factories.user(claude_oauth_token: "oat-test", github_token: "ghp-test")
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    chat = ChatSession.create!(repository: repository, user: user)
    message = chat.messages.create!(role: "user", content: { text: "hello" })

    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, chat)
    job.instance_variable_set(:@user_message, message)

    {
      "chat (essential tier)" => job.send(:stdio_chat_server_config, tier: "essential", always_load: true),
      "chat (deferred tier)" => job.send(:stdio_chat_server_config, tier: "deferred", always_load: false)
    }
  end

  it "classifies the sidecar entrypoints it is meant to guard as Rails processes" do
    # Guards the guard: if `boots_rails?` ever stops recognizing a sidecar, the
    # main example below would pass by skipping everything.
    expect(boots_rails?(Rails.root.join("bin/syrus-chat-sidecar"))).to be(true)
    expect(boots_rails?(Rails.root.join("bin/syrus-chat-deferred-sidecar"))).to be(true)
    expect(boots_rails?(Rails.root.join("bin/syrus-mcp-sidecar"))).to be(true)

    # The secret-free bridge to the selected daemon is deliberately NOT a Rails
    # process, which is why it is safe under a scrubbed environment.
    expect(boots_rails?(Rails.root.join("bin/syrus-mcp-proxy"))).to be(false)
  end

  it "never configures a Rails-booting stdio MCP command with an environment it cannot boot under" do
    with_boot_secrets_in_env do
      offenders = stdio_configs.filter_map do |label, config|
        command = config[:command] || config["command"]
        next unless boots_rails?(command)

        env = (config[:env] || config["env"]).to_h
        missing = REQUIRED_BOOT_SECRETS - env.keys
        next if missing.empty?

        "#{label}: #{File.basename(command.to_s)} is a Rails process but its " \
          "environment is missing #{missing.join(', ')}"
      end

      expect(offenders).to be_empty, <<~MSG
        A stdio MCP sidecar was configured with an agent-scrubbed environment.
        It will fail to boot on any deployment that supplies secrets through the
        environment, and the agent turn will run with no MCP tools at all.

        #{offenders.join("\n")}

        Do NOT fix this by restoring the secrets: the MCP config is agent-readable,
        and spec/jobs/chat_turn_job_spec.rb requires the chat sidecar env to carry
        none of them. Point the agent at the secret-free bin/syrus-mcp-proxy, or
        make this path refuse clearly instead of spawning a process that cannot boot.
      MSG
    end
  end

  it "keeps .build and .build_boot meaningfully different" do
    # The whole invariant rests on this distinction, so pin it.
    with_boot_secrets_in_env do
      expect(AgentSidecarEnvironment.build.keys).not_to include(*REQUIRED_BOOT_SECRETS)
      expect(AgentSidecarEnvironment.build_boot.keys).to include(*REQUIRED_BOOT_SECRETS)
    end
  end
end
