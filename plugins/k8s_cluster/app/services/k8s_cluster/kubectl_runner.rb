require "open3"

module K8sCluster
  class KubectlRunner
    Result = Data.define(:stdout, :stderr, :status) do
      def success? = status.to_i.zero?
    end

    def self.call(env:, argv:)
      stdout, stderr, process_status = Open3.capture3(env, *argv)
      Result.new(stdout: stdout, stderr: stderr, status: process_status.exitstatus || 1)
    end
  end
end
