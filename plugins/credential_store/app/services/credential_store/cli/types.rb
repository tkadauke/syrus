module CredentialStore::Cli
  class Types < Base
    def call(args:, flags:, user:)
      types = payload(user).dig(:options, :credential_types).map do |type|
        type.slice(:name, :label, :description, :plugin).transform_values(&:to_s)
      end
      return json_text(types) if flags["json"]
      return self.class.text("No credential types.") if types.empty?

      rows = types.map { |type| [ type[:name], value_or_dash(type[:label]), value_or_dash(type[:plugin]), value_or_dash(type[:description]) ] }
      self.class.table(columns: [ "NAME", "LABEL", "PLUGIN", "DESCRIPTION" ], rows: rows)
    end
  end
end
