require "fileutils"
require "json"

class CodexAuth
  class Error < AgentProviders::ConfigurationError; end

  DEFAULT_REFRESH_LOCK_TIMEOUT_SECONDS = 30.minutes.to_i

  Result = Data.define(:api_key)

  class << self
    def with_refresh_lock(user:, timeout: DEFAULT_REFRESH_LOCK_TIMEOUT_SECONDS)
      return yield unless user.codex_auth_mode == "chatgpt_login"

      if mysql?
        with_mysql_refresh_lock(user, timeout: timeout) { yield }
      else
        with_local_refresh_lock(user) { yield }
      end
    end

    private

    def mysql?
      ActiveRecord::Base.connection.adapter_name.match?(/mysql/i)
    end

    def with_mysql_refresh_lock(user, timeout:)
      lock_name = "syrus:codex_auth:user:#{user.id}"

      ActiveRecord::Base.connection_pool.with_connection do |connection|
        quoted_name = connection.quote(lock_name)
        result = connection.select_value("SELECT GET_LOCK(#{quoted_name}, #{Integer(timeout)})")
        unless result.to_i == 1
          raise Error, "Timed out waiting for another Codex ChatGPT login refresh to finish"
        end

        begin
          user.reload
          yield
        ensure
          connection.select_value("SELECT RELEASE_LOCK(#{quoted_name})")
        end
      end
    end

    def with_local_refresh_lock(user)
      local_refresh_mutex_for(user.id).synchronize do
        user.reload
        yield
      end
    end

    def local_refresh_mutex_for(user_id)
      @local_refresh_mutex_guard ||= Mutex.new
      @local_refresh_mutexes ||= {}
      @local_refresh_mutex_guard.synchronize do
        @local_refresh_mutexes[user_id] ||= Mutex.new
      end
    end
  end

  def initialize(user:, codex_home:, runner: nil)
    @user = user
    @codex_home = codex_home.to_s
    @runner = runner || method(:default_runner)
  end

  def prepare!
    case @user.codex_auth_mode
    when "api_key"
      prepare_api_key
    when "chatgpt_login"
      prepare_chatgpt_login
    else
      raise Error, "Unknown Codex auth mode: #{@user.codex_auth_mode.inspect}"
    end
  end

  def persist_updated_auth_json
    return unless @user.codex_auth_mode == "chatgpt_login"
    return unless File.exist?(auth_path)

    auth_json = normalized_auth_json(File.read(auth_path))
    @user.reload
    @user.update!(codex_auth_json: auth_json) if @user.codex_auth_json != auth_json
  rescue StandardError => e
    Rails.logger.warn(
      "Failed to persist refreshed Codex auth.json for user #{@user.id}: #{e.message}"
    )
  end

  private

  def prepare_api_key
    raise Error, "Codex API key is not configured" if @user.codex_api_key.blank?

    Result.new(api_key: @user.codex_api_key)
  end

  def prepare_chatgpt_login
    raise Error, "Codex auth.json is not configured" if @user.codex_auth_json.blank?

    FileUtils.mkdir_p(@codex_home)
    @runner.call(
      codex_home: @codex_home,
      auth_json: normalized_auth_json(@user.codex_auth_json)
    )
    Result.new(api_key: nil)
  end

  def default_runner(codex_home:, auth_json:)
    FileUtils.mkdir_p(codex_home)
    auth_path = File.join(codex_home, "auth.json")
    return if File.exist?(auth_path) && File.read(auth_path) == auth_json

    File.write(auth_path, auth_json)
    File.chmod(0o600, auth_path)
  end

  def normalized_auth_json(raw_json)
    parsed = JSON.parse(raw_json)
    unless parsed.is_a?(Hash)
      raise Error, "Codex auth.json must be a JSON object with ChatGPT tokens"
    end

    tokens = parsed["tokens"]
    unless tokens.is_a?(Hash)
      raise Error, "Codex auth.json must be a JSON object with ChatGPT tokens"
    end

    %w[ id_token access_token refresh_token ].each do |key|
      raise Error, "Codex auth.json is missing tokens.#{key}" if tokens[key].blank?
    end

    JSON.pretty_generate(parsed) + "\n"
  rescue JSON::ParserError => e
    raise Error, "Codex auth.json is not valid JSON: #{e.message}"
  end

  def auth_path
    File.join(@codex_home, "auth.json")
  end
end
