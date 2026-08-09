require "singleton"

module Tailscale
  class DaemonManager
    include Singleton

    SOCKET_PATH           = "/tmp/tailscaled.sock"
    STATE_PATH            = "/tmp/tailscaled.state"
    READY_TIMEOUT_SECONDS = 30
    READY_POLL_INTERVAL   = 0.5

    def start
      return unless worker_context?
      return if alive?

      @pid = Process.spawn(
        "tailscaled",
        "--state=#{STATE_PATH}",
        "--socket=#{SOCKET_PATH}",
        out: File::NULL,
        err: File::NULL
      )
      Process.detach(@pid)
      wait_until_ready!
      run_tailscale_up!
      run_tailscale_serve!
    end

    def alive?
      return false unless @pid

      Process.kill(0, @pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def restart_if_dead
      start unless alive?
    end

    def stop
      begin
        run_tailscale_logout
      rescue StandardError => e
        Rails.logger.warn("[Tailscale::DaemonManager] tailscale logout failed: #{e.message}")
      end

      if @pid
        begin
          Process.kill("TERM", @pid)
        rescue Errno::ESRCH
          nil
        end
        @pid = nil
      end
    end

    private

    def worker_context?
      ENV["SOLID_QUEUE_IN_PUMA"].present? || $PROGRAM_NAME.end_with?("jobs")
    end

    def wait_until_ready!
      deadline = Time.now + READY_TIMEOUT_SECONDS
      loop do
        return if daemon_ready?
        raise "tailscaled did not become ready within #{READY_TIMEOUT_SECONDS}s" if Time.now >= deadline

        sleep READY_POLL_INTERVAL
      end
    end

    def daemon_ready?
      UNIXSocket.open(SOCKET_PATH) do |sock|
        sock.write("GET /localapi/v0/status HTTP/1.0\r\nHost: local\r\n\r\n")
        sock.flush
        first_line = sock.gets
        first_line&.include?(" 200 ") || false
      end
    rescue StandardError
      false
    end

    def run_tailscale_up!
      args = [ "tailscale", "--socket=#{SOCKET_PATH}", "up",
               "--authkey=#{ENV['TS_AUTHKEY']}" ]
      hostname = plugin_config("hostname")
      args << "--hostname=#{hostname}" if hostname.present?
      system(*args)
    end

    def run_tailscale_serve!
      internal_url = ENV.fetch("SYRUS_INTERNAL_WEB_URL", "http://web:80")
      system("tailscale", "--socket=#{SOCKET_PATH}", "serve",
             "--bg", "--https=443", internal_url)
    end

    def run_tailscale_logout
      system("tailscale", "--socket=#{SOCKET_PATH}", "logout",
             out: File::NULL, err: File::NULL)
    end

    def plugin_config(key)
      PluginRecord.find_by(name: "tailscale")&.config&.dig(key)
    rescue StandardError
      nil
    end
  end
end
