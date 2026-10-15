require "shellwords"

class FocusedTestCommandTemplate
  def self.interpolate(template, files:, failed_count:)
    substitutions = {
      "{files}" => Shellwords.join(files),
      "{failed_count}" => failed_count.to_s
    }

    template.to_s.gsub(/\{files\}|\{failed_count\}/) { |placeholder| substitutions.fetch(placeholder) }
  end
end
