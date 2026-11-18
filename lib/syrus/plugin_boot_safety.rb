# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"

module Syrus
  # Database-independent plugin boot ledger. It is deliberately usable by the
  # loader and recovery command before Rails or any plugin code is evaluated.
  class PluginBootSafety
    REQUIRED_FOR_BOOT = [].freeze
    MODES = %w[third_party recent all].freeze

    attr_reader :path

    class << self
      def attempt_leases = @attempt_leases ||= {}
    end

    def self.default(env: ENV, clock: -> { Time.now.utc })
      data_root = env.fetch("SYRUS_DATA_ROOT", File.expand_path("~/.syrus"))
      new(path: File.join(data_root, "plugin-boot-safety.json"), env:, clock:)
    end

    def initialize(path:, env: ENV, clock: -> { Time.now.utc })
      @path = Pathname.new(path)
      @env = env
      @clock = clock
    end

    def begin_boot!(plugins)
      attempt_id = SecureRandom.uuid
      hold_attempt_lease(attempt_id)
      update do |state|
        prune_attempts!(state)
        changed = changed_external_plugins(plugins, state)
        if failed_attempts(state).length >= failure_limit
          changed.each { |plugin| state["quarantines"][plugin.name] ||= "changed since the last good boot after a crash loop" }
        end
        state["attempts"] << { "id" => attempt_id, "at" => now.iso8601 }
      end
      attempt_id
    rescue StandardError
      release_attempt_lease(attempt_id)
      raise
    end

    def mark_good!(plugins, attempt_id: nil)
      update do |state|
        attempts = Array(state["attempts"])
        if attempt_id && (successful_index = attempts.index { |attempt| attempt["id"] == attempt_id })
          state["attempts"] = attempts.each_with_index.filter_map do |attempt, index|
            next if attempt["id"] == attempt_id
            next if index < successful_index && !attempt_active?(attempt.fetch("id"))

            attempt
          end
        elsif attempt_id
          state["attempts"] = attempts
        else
          state["attempts"] = []
        end
        state["last_good_at"] = now.iso8601
        state["last_good_plugins"] = plugins.to_h { |plugin| [ plugin.name, fingerprint(plugin.directory) ] }
      end
    ensure
      release_attempt_lease(attempt_id) if attempt_id
    end

    def skip_reason(plugin)
      return "fleet quarantine in desired plugin state" if fleet_quarantines.key?(plugin.name)
      return state.fetch("quarantines", {})[plugin.name] if state.fetch("quarantines", {}).key?(plugin.name)

      SafeMode.for(mode, self).skip_reason(plugin)
    end

    def active?
      !mode.to_s.empty? || quarantines.any? || fleet_quarantines.any?
    end

    def mode
      value = @env["SYRUS_SAFE_MODE"].to_s.strip
      value unless value.empty?
    end
    def quarantines = state.fetch("quarantines", {}).merge(fleet_quarantines)
    def local_quarantines = state.fetch("quarantines", {})
    def last_good_fingerprint(name) = state.fetch("last_good_plugins", {})[name]

    def locally_clearable?(name)
      mode.to_s.empty? && !fleet_quarantines.key?(name.to_s) && local_quarantines.key?(name.to_s)
    end

    def quarantine!(name, reason: "manually quarantined by an administrator")
      update { |value| value["quarantines"][name.to_s] = reason }
    end

    def clear!(name)
      removed = false
      update { |value| removed = !!value["quarantines"].delete(name.to_s) }
      removed
    end

    def fleet_quarantines
      file = path.dirname.join("plugin-sync/fleet-quarantines.json")
      return {} unless file.file?

      JSON.parse(file.read).to_h.transform_values { |value| value.to_s.empty? ? "fleet quarantine in desired plugin state" : value.to_s }
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def fingerprint(directory)
      digest = Digest::SHA256.new
      Pathname.new(directory).glob("**/*").select(&:file?).sort.each do |file|
        digest << file.relative_path_from(directory).to_s << "\0" << file.binread << "\0"
      end
      digest.hexdigest
    end

    private

    def state
      return empty_state unless path.file?

      empty_state.merge(JSON.parse(path.read)).tap { |value| value["quarantines"] ||= {} }
    rescue JSON::ParserError, SystemCallError
      empty_state
    end

    def empty_state = { "attempts" => [], "quarantines" => {}, "last_good_plugins" => {} }
    def now = @clock.call.utc
    def failure_limit = Integer(@env.fetch("SYRUS_BOOT_FAILURE_LIMIT", "3"), 10)
    def failure_window = Integer(@env.fetch("SYRUS_BOOT_FAILURE_WINDOW_SECONDS", "600"), 10)
    def failed_attempts(value)
      Array(value["attempts"]).reject { |attempt| attempt_active?(attempt.fetch("id")) }
    end

    def attempt_lease_path(id) = Pathname.new("#{path}.attempt-#{id}.lock")

    def hold_attempt_lease(id)
      lease = File.open(attempt_lease_path(id), File::RDWR | File::CREAT, 0o600)
      lease.flock(File::LOCK_EX)
      self.class.attempt_leases[[ path.to_s, id ]] = lease
    end

    def release_attempt_lease(id)
      lease = self.class.attempt_leases.delete([ path.to_s, id ])
      lease&.close
      FileUtils.rm_f(attempt_lease_path(id))
    end

    def attempt_active?(id)
      File.open(attempt_lease_path(id), File::RDWR | File::CREAT, 0o600) do |lease|
        acquired = lease.flock(File::LOCK_EX | File::LOCK_NB)
        lease.flock(File::LOCK_UN) if acquired
        !acquired
      end
    end

    def prune_attempts!(value)
      cutoff = now - failure_window
      value["attempts"] = Array(value["attempts"]).select { |attempt| Time.iso8601(attempt.fetch("at")) >= cutoff rescue false }
      value["quarantines"] ||= {}
    end

    def changed_external_plugins(plugins, value)
      good = value.fetch("last_good_plugins", {})
      plugins.select { |plugin| plugin.external && good[plugin.name] != fingerprint(plugin.directory) }
    end

    def update
      FileUtils.mkdir_p(path.dirname)
      temporary = nil
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        value = state
        yield value
        temporary = Pathname.new("#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}")
        File.write(temporary, JSON.pretty_generate(value) + "\n")
        File.rename(temporary, path)
      end
    ensure
      FileUtils.rm_f(temporary) if temporary&.exist?
    end

    class SafeMode
      def self.for(name, ledger)
        { nil => Off, "" => Off, "third_party" => ThirdParty, "recent" => Recent, "all" => All }
          .fetch(name) do
            warn "Invalid SYRUS_SAFE_MODE #{name.inspect}; expected #{MODES.join(', ')}. Continuing without safe mode."
            Off
          end
          .new(ledger)
      end

      def initialize(ledger) = @ledger = ledger
      def skip_reason(_plugin) = nil

      class Off < SafeMode; end

      class ThirdParty < SafeMode
        def skip_reason(plugin)
          "safe mode third_party excludes external plugins" if plugin.external
        end
      end

      class Recent < SafeMode
        def skip_reason(plugin)
          return unless plugin.external
          return if @ledger.last_good_fingerprint(plugin.name) == @ledger.fingerprint(plugin.directory)

          "safe mode recent excludes plugins changed since the last good boot"
        end
      end

      class All < SafeMode
        def skip_reason(plugin)
          "safe mode all excludes plugins not required for boot" unless REQUIRED_FOR_BOOT.include?(plugin.name)
        end
      end
    end
  end
end
