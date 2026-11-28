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
      cached_command = "#{shell_join(command_parts + compilation_cache_build_settings)} COMPILATION_CACHE_CAS_PATH=\"$syrus_xcode_cache_path\""
      uncached_command = shell_join(command_parts)

      <<~BASH
        set -o pipefail
        rm -rf #{shell_join([ result_bundle_path ])}
        mkdir -p #{shell_join([ File.dirname(derived_data_path), File.dirname(result_bundle_path), File.dirname(cache_diagnostic_path) ])}
        : > #{shell_join([ cache_diagnostic_path ])}
        syrus_xcode_cache_note() { printf 'Syrus Xcode compilation cache: %s\n' "$1" | tee -a #{shell_join([ cache_diagnostic_path ])}; }
        syrus_xcode_cache_probe() { perl -e '$SIG{ALRM}=sub { exit 124 }; alarm shift; exec @ARGV' 10 "$@"; }
        syrus_xcode_cache_enabled=#{compilation_cache_enabled?}
        syrus_xcode_cache_supported=false
        syrus_xcode_version="$(syrus_xcode_cache_probe xcodebuild -version 2>/dev/null || true)"
        syrus_xcode_major="$(printf '%s\n' "$syrus_xcode_version" | awk '/^Xcode / { split($2, version, "."); print version[1]; exit }')"
        if [ "$syrus_xcode_cache_enabled" = true ] && [ "${syrus_xcode_major:-0}" -ge 26 ] 2>/dev/null &&
           syrus_xcode_cache_probe xcrun swiftc -help-hidden 2>&1 | grep -q -- '-cache-compile-job'; then
          syrus_xcode_cache_supported=true
        fi

        if [ "$syrus_xcode_cache_enabled" != true ]; then
          syrus_xcode_cache_note 'disabled by grader configuration; running uncached'
          #{uncached_command} 2>&1 | tee -a #{shell_join([ cache_diagnostic_path ])}
          exit ${PIPESTATUS[0]}
        elif [ "$syrus_xcode_cache_supported" != true ]; then
          syrus_xcode_cache_note "unsupported or probe unhealthy (${syrus_xcode_version:-version unavailable}); running uncached"
          #{uncached_command} 2>&1 | tee -a #{shell_join([ cache_diagnostic_path ])}
          exit ${PIPESTATUS[0]}
        fi

        syrus_xcode_cache_root="${SYRUS_XCODE_COMPILATION_CACHE_ROOT:-${SYRUS_DATA_ROOT:-/var/lib/syrus}/cache/xcode-compilation}"
        case "$syrus_xcode_cache_root" in
          /*/*/*) ;;
          *)
            syrus_xcode_cache_note "unsafe cache root $syrus_xcode_cache_root; running uncached"
            #{uncached_command} 2>&1 | tee -a #{shell_join([ cache_diagnostic_path ])}
            exit ${PIPESTATUS[0]}
            ;;
        esac
        case "/$syrus_xcode_cache_root/" in
          */../*)
            syrus_xcode_cache_note "unsafe cache root $syrus_xcode_cache_root; running uncached"
            #{uncached_command} 2>&1 | tee -a #{shell_join([ cache_diagnostic_path ])}
            exit ${PIPESTATUS[0]}
            ;;
        esac
        syrus_xcode_toolchain="$(printf '%s' "$syrus_xcode_version" | shasum -a 256 | cut -c1-16)"
        syrus_xcode_generation="$(date +%Y-%U)"
        syrus_xcode_cache_path="$syrus_xcode_cache_root/$syrus_xcode_toolchain/$syrus_xcode_generation"
        if ! mkdir -p "$syrus_xcode_cache_path" 2>/dev/null || [ ! -w "$syrus_xcode_cache_path" ]; then
          syrus_xcode_cache_note "unavailable at $syrus_xcode_cache_path; running uncached"
          #{uncached_command} 2>&1 | tee -a #{shell_join([ cache_diagnostic_path ])}
          exit ${PIPESTATUS[0]}
        fi

        syrus_xcode_active="$syrus_xcode_cache_path/.syrus-active-$$"
        : > "$syrus_xcode_active"
        trap 'rm -f "$syrus_xcode_active"' EXIT
        trap 'exit 130' HUP INT TERM
        find "$syrus_xcode_cache_root" -mindepth 2 -maxdepth 2 -type d -mtime +#{cache_retention_days} -print 2>/dev/null |
          while IFS= read -r syrus_xcode_stale; do
            if ! find "$syrus_xcode_stale" -maxdepth 1 -name '.syrus-active-*' -print -quit 2>/dev/null | grep -q .; then
              rm -rf -- "$syrus_xcode_stale"
            fi
          done
        syrus_xcode_cache_note "enabled; path=$syrus_xcode_cache_path; retention=#{cache_retention_days}d; diagnostic remarks enabled"
        #{cached_command} 2>&1 | tee -a #{shell_join([ cache_diagnostic_path ])}
        syrus_xcode_status=${PIPESTATUS[0]}
        if [ "$syrus_xcode_status" -ne 0 ] && grep -Eiq '(CAS|compilation cache).*(error|failed|corrupt|unavailable)|(error|failed).*(CAS|compilation cache)' #{shell_join([ cache_diagnostic_path ])}; then
          syrus_xcode_cache_note 'cache became unhealthy; retrying once with native caching disabled'
          rm -rf #{shell_join([ result_bundle_path ])}
          #{uncached_command} 2>&1 | tee -a #{shell_join([ cache_diagnostic_path ])}
          exit ${PIPESTATUS[0]}
        fi
        exit "$syrus_xcode_status"
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

    def compilation_cache_enabled?
      return true unless config.key?("compilation_cache")
      return config["compilation_cache"] if [ true, false ].include?(config["compilation_cache"])

      raise ArgumentError, "compilation_cache must be true or false"
    end

    def cache_retention_days
      raw = config["compilation_cache_retention_days"].presence || 21
      days = Integer(raw)
      raise ArgumentError unless days.between?(1, 90)

      days
    rescue ArgumentError, TypeError
      raise ArgumentError, "compilation_cache_retention_days must be an integer from 1 to 90"
    end

    def compilation_cache_build_settings
      [
        "COMPILATION_CACHE_ENABLE_CACHING=YES",
        "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES"
      ]
    end

    def cache_diagnostic_path
      project_relative("build/syrus/#{artifact_name}-compilation-cache.log")
    end

    def artifact_outputs
      [
        { "artifact" => result_bundle_path, "format" => "xcresult" },
        { "artifact" => derived_data_path, "format" => "derived_data" },
        { "artifact" => cache_diagnostic_path, "format" => "xcode_compilation_cache_log" }
      ]
    end

    def metadata
      super.merge(
        "compilation_cache" => {
          "requested" => compilation_cache_enabled?,
          "provider" => "xcode_native_cas",
          "diagnostic_artifact" => cache_diagnostic_path,
          "retention_days" => cache_retention_days
        }
      )
    end
  end
end
