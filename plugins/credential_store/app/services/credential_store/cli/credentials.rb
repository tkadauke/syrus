module CredentialStore::Cli
  class Credentials < Base
    def call(args:, flags:, user:)
      credentials = payload(user).fetch(:credentials).map { |credential| normalize(credential) }
      credentials = credentials.select { |credential| credential[:credential_type] == flags["type"] } if flags["type"].present?
      return json_text(credentials) if flags["json"]
      return self.class.text("No credentials.") if credentials.empty?

      rows = credentials.map do |credential|
        [ credential[:id], credential[:name], credential[:credential_type], scope_label(credential), credential[:active] ? "yes" : "no", format_map(credential[:safe_metadata]) ]
      end
      self.class.table(columns: [ "ID", "NAME", "TYPE", "SCOPE", "ACTIVE", "SAFE METADATA" ], rows: rows)
    end

    private

    def normalize(credential)
      {
        id: credential[:id].to_i,
        name: credential[:name].to_s,
        description: credential[:description].to_s,
        credential_type: credential[:credential_type].to_s,
        scope_type: credential[:scope_type].to_s,
        scope_id: credential[:scope_id].to_i,
        scope_label: credential[:scope_label].to_s,
        safe_metadata: credential[:safe_metadata].to_h,
        target_constraints: credential[:target_constraints].to_h,
        allowed_surfaces: Array(credential[:allowed_surfaces]),
        allowed_tools: Array(credential[:allowed_tools]),
        expires_at: credential[:expires_at].to_s,
        revoked_at: credential[:revoked_at].to_s,
        active: !!credential[:active]
      }
    end

    def scope_label(credential)
      return credential[:scope_label] if credential[:scope_label].present?
      return credential[:scope_type] if credential[:scope_id].blank?

      "#{credential[:scope_type]}:#{credential[:scope_id]}"
    end

    def format_map(values)
      values.to_h.sort.map { |key, value| "#{key}=#{value}" }.join(",").presence || "-"
    end
  end
end
