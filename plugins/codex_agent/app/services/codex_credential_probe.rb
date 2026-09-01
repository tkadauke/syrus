require "fileutils"
require "json"
require "tmpdir"

class CodexCredentialProbe
  CREDENTIAL_SPECS = {
    "codex_api_key" => {
      credential_attr: :codex_api_key,
      missing_message: "Codex API key is not configured.",
      required_mode: "api_key",
      wrong_mode_message: "Codex is set to ChatGPT auth.json mode."
    },
    "codex_auth_json" => {
      credential_attr: :codex_auth_json,
      missing_message: "Codex ChatGPT auth.json is not configured.",
      required_mode: "chatgpt_login",
      wrong_mode_message: "Codex is set to API key mode."
    }
  }.freeze

  SECRET_EXTRACTOR = lambda do |user|
    secrets = [ user.codex_api_key ]
    if user.codex_auth_json.present?
      begin
        secrets.concat(JSON.parse(user.codex_auth_json).dig("tokens").to_h.values)
      rescue JSON::ParserError
        nil
      end
    end
    secrets
  end.freeze

  def self.call(probe)
    new(probe).call
  end

  def initialize(probe)
    @probe = probe
  end

  def call
    spec = CREDENTIAL_SPECS.fetch(credential)
    return missing(spec[:missing_message]) if user.send(spec[:credential_attr]).blank?
    return wrong_mode(spec[:wrong_mode_message]) unless user.codex_auth_mode == spec[:required_mode]

    Dir.mktmpdir("syrus-codex-probe-") do |workspace|
      codex_home = File.join(workspace, ".codex")
      FileUtils.mkdir_p(codex_home)
      CodexAuth.with_refresh_lock(user: user) do
        codex_auth = CodexAuth.new(user: user, codex_home: codex_home)
        auth = codex_auth.prepare!
        File.write(File.join(codex_home, "config.toml"), codex_config)

        output = +""
        result = ProcessRunner.new(
          env: ProcessRunner.forwarded_env(
            AgentInvocation::ENV_FORWARD,
            extra: {
              "CODEX_HOME" => codex_home,
              "CODEX_API_KEY" => auth.api_key.presence
            }
          ),
          command: [
            "codex", "exec",
            "--cd", workspace,
            "--dangerously-bypass-approvals-and-sandbox",
            "--json",
            "Reply with OK."
          ],
          chdir: workspace,
          timeout: CredentialProbe::TIMEOUT_SECONDS,
          silent_timeout: 15,
          kind: "agent",
          on_output_chunk: ->(chunk) { append_output(output, chunk) }
        ).run

        if result.success?
          codex_auth.persist_updated_auth_json
          return CredentialProbe::Result.new(
            credential: credential,
            ok: true,
            message: "Codex credentials are valid.",
            details: success_details
          )
        end

        failure("Codex probe failed: #{probe_failure_reason(result, output)}")
      end
    end
  rescue CodexAuth::Error => e
    failure(e.message)
  rescue Errno::ENOENT
    failure("Codex CLI is not installed or not on PATH.")
  end

  private

  attr_reader :probe

  def user = probe.send(:user)

  def credential = probe.send(:credential)

  def missing(message) = probe.send(:missing, message)

  def wrong_mode(message) = probe.send(:wrong_mode, message)

  def failure(message) = probe.send(:failure, message)

  def append_output(output, chunk) = probe.send(:append_output, output, chunk)

  def probe_failure_reason(result, output) = probe.send(:probe_failure_reason, result, output)

  def success_details
    return {} unless user.codex_auth_mode == "chatgpt_login"

    usage = CodexUsageProbe.refresh_for(user: user, force: true)
    usage.snapshot.present? ? { codex_usage: usage.snapshot } : {}
  end

  def codex_config
    [
      'cli_auth_credentials_store = "file"',
      'approval_policy = "never"',
      "model = #{JSON.generate(CodexInvocation::DEFAULT_MODEL)}"
    ].join("\n") + "\n"
  end
end
