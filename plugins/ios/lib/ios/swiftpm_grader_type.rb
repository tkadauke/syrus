require "ios/base_grader_type"

module Ios
  class SwiftpmGraderType < BaseGraderType
    def self.type_name
      "swiftpm"
    end

    private

    def framework
      "swiftpm"
    end

    def default_name
      "swiftpm-tests"
    end

    def default_display_name
      "Swift Package Manager tests"
    end

    def mode
      action
    end

    def action
      value = config["action"].to_s.strip.presence || "test"
      return value if %w[build test].include?(value)

      raise ArgumentError, "action must be build or test"
    end

    def command
      <<~BASH.squish
        { rm -rf #{shell_join([ build_path ])};
          mkdir -p #{shell_join([ File.dirname(build_path) ])};
          #{shell_join(command_parts)};
        }
      BASH
    end

    def command_parts
      [
        "swift",
        action,
        *package_path_flags,
        "--build-path", build_path,
        *configuration_flags,
        *extra_arguments
      ]
    end

    def package_path_flags
      path = package_path
      path == "." ? [] : [ "--package-path", path ]
    end

    def package_path
      raw = config["package_path"].presence || config["path"].presence || project_path.presence || "."
      project_relative(raw.to_s.strip.presence || ".")
    end

    def build_path
      project_relative(config["build_path"].presence || ".syrus/DerivedData/#{artifact_name}")
    end

    def configuration_flags
      configuration = config["configuration"].to_s.strip.presence
      configuration ? [ "-c", configuration ] : []
    end

    def extra_arguments
      shell_array(config["args"] || config["arguments"])
    end

    def artifact_outputs
      [ { "artifact" => build_path, "format" => "swiftpm_build" } ]
    end
  end
end
