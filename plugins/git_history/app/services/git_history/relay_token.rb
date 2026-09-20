module GitHistory
  # Shared secret authorizing requests between GitHistory::RelayClient (web
  # process) and GitHistory::RelayServer (worker process). RelayServer binds
  # 0.0.0.0 with no network-layer restriction, so anything else reachable on
  # that port could otherwise read any repository's bare-clone history
  # directly, bypassing GitHistoryController's `Repository.accessible_to`
  # check entirely. Both processes already share the app's
  # `secret_key_base`, so deriving the token from it (via Rails' own key
  # generator, scoped to a fixed purpose) needs no extra deployment config
  # and never puts the raw secret_key_base on the wire.
  module RelayToken
    PURPOSE = "git_history_relay_token".freeze
    LENGTH = 32

    def self.value
      @value ||= Rails.application.key_generator.generate_key(PURPOSE, LENGTH).unpack1("H*")
    end
  end
end
