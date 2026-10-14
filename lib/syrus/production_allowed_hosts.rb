# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module Syrus
  module ProductionAllowedHosts
    module_function

    def resolve(app_host:, raw_allowed_hosts:)
      parsed_hosts = raw_allowed_hosts.to_s
        .split(",")
        .map(&:strip)
        .reject(&:blank?)

      ([app_host] + parsed_hosts).uniq
    end

    def blank_env?(env = ENV)
      env.key?("SYRUS_ALLOWED_HOSTS") && env["SYRUS_ALLOWED_HOSTS"].blank?
    end
  end
end
