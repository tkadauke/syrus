require "tmpdir"
require "fileutils"

module RuntimeImages
  module BuildNetwork
    # One build's egress: a policy snapshot enforced by a running proxy, plus
    # the environment and relay command that point the build at it.
    class Session
      RELAY_PORT = 3128
      RELAY_SCRIPT = Rails.root.join("bin/runtime-image-build-relay")
      PROXY_URL = "http://127.0.0.1:#{RELAY_PORT}".freeze

      def self.open(policy:, resolver: Resolver.new)
        dir = Dir.mktmpdir("rib")
        proxy = Proxy.new(policy: policy, socket_path: File.join(dir, "proxy.sock"), resolver: resolver).start
        yield new(dir: dir, proxy: proxy, policy: policy)
      ensure
        proxy&.stop
        FileUtils.rm_rf(dir) if dir
      end

      attr_reader :dir, :policy

      def initialize(dir:, proxy:, policy:)
        @dir = dir
        @proxy = proxy
        @policy = policy
      end

      def socket_path = @proxy.socket_path
      def summary = @proxy.summary

      # Every conventional proxy variable, so build tools that read only one
      # spelling still go through the proxy. NO_PROXY is empty: nothing is
      # exempt from the policy.
      def environment
        %w[HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy].to_h { |name| [ name, PROXY_URL ] }
                                                                                 .merge("NO_PROXY" => "", "no_proxy" => "")
      end

      def relay_command
        [ RbConfig.ruby, RELAY_SCRIPT.to_s, socket_path, RELAY_PORT.to_s ]
      end
    end
  end
end
