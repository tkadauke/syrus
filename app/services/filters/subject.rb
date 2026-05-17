module Filters
  Subject = Data.define(:name, :model, :chips) do
    def initialize(name:, model:, chips:)
      super(name: name.to_sym, model: model, chips: chips.stringify_keys.freeze)
    end

    def chip_class(field)
      class_name = chips[field.to_s] or raise UnknownFilterField.new(field)
      class_name.constantize
    end

    alias_method :find_chip, :chip_class

    def fields
      chips.keys
    end

    def exists?(field)
      chips.key?(field.to_s)
    end
  end
end
