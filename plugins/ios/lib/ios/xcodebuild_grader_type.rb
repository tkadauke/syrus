require "ios/base_grader_type"

module Ios
  class XcodebuildGraderType < BaseGraderType
    DEFAULT_DESTINATION = "platform=iOS Simulator,name=iPhone 16,OS=latest".freeze

    def self.type_name
      "xcodebuild"
    end

    private

    def framework
      "xcodebuild"
    end

    def default_name
      "ios-tests"
    end

    def default_display_name
      "iOS simulator tests"
    end

    def mode
      action
    end

    def action
      config["action"].to_s.strip.presence || "test"
    end

    def command
      <<~BASH.squish
        { rm -rf #{shell_join([ result_bundle_path ])};
          mkdir -p #{shell_join([ File.dirname(derived_data_path), File.dirname(result_bundle_path) ])};
          #{shell_join(command_parts)};
        }
      BASH
    end

    def command_parts
      [
        "xcodebuild",
        action,
        *container_flags,
        "-scheme", scheme,
        "-destination", destination,
        "-derivedDataPath", derived_data_path,
        "-resultBundlePath", result_bundle_path,
        *extra_arguments,
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO"
      ]
    end

    def container_flags
      workspace = config["workspace"].to_s.strip.presence
      project = config["project"].to_s.strip.presence
      raise ArgumentError, "set exactly one of workspace or project" if workspace.present? == project.present?

      workspace ? [ "-workspace", project_relative(workspace) ] : [ "-project", project_relative(project) ]
    end

    def scheme
      value = config["scheme"].to_s.strip.presence
      raise ArgumentError, "scheme is required" unless value

      value
    end

    def destination
      config["destination"].to_s.strip.presence || DEFAULT_DESTINATION
    end

    def derived_data_path
      project_relative(config["derived_data_path"].presence || ".syrus/DerivedData/#{artifact_name}")
    end

    def result_bundle_path
      project_relative(config["result_bundle_path"].presence || "build/syrus/#{artifact_name}.xcresult")
    end

    def extra_arguments
      shell_array(config["args"] || config["arguments"])
    end

    def artifact_outputs
      [
        { "artifact" => result_bundle_path, "format" => "xcresult" },
        { "artifact" => derived_data_path, "format" => "derived_data" }
      ]
    end
  end
end
