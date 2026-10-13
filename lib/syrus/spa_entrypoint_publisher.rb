require "fileutils"
require "pathname"

module Syrus
  class SpaEntrypointPublisher
    def initialize(source_path:, output_path:)
      @source_path = Pathname.new(source_path)
      @output_path = Pathname.new(output_path)
    end

    def call
      raise "SPA entrypoint is missing: #{source_path}" unless source_path.file?

      output_path.mkpath
      target = output_path.join("spa.js")
      FileUtils.cp(source_path, target)
      target
    end

    private
      attr_reader :source_path, :output_path
  end
end
