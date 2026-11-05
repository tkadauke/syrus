module Permissions
  class ToolSetBundle
    IDENTIFIER_PATTERN = /\A[a-z][a-z0-9_.-]*@v[1-9]\d*\z/

    attr_reader :key, :label, :description

    def initialize(key:, label:, description:)
      @key = key.to_s.freeze
      @label = label.to_s.freeze
      @description = description.to_s.freeze
      raise ArgumentError, "tool-set bundle key must be versioned" unless @key.match?(IDENTIFIER_PATTERN)
      raise ArgumentError, "tool-set bundle label is required" if @label.empty?
      raise ArgumentError, "tool-set bundle description is required" if @description.empty?
      freeze
    end

    def to_h = { key:, label:, description: }
  end
end
