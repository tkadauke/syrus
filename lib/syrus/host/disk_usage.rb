module Syrus
  module Host
    module DiskUsage
      def self.read(path)
        DataRootDiskUsage.read(path)
      end
    end
  end
end
