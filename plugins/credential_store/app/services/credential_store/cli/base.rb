# frozen_string_literal: true

module CredentialStore
  module Cli
    class Base < Syrus::Host::CliCommandHandler
      private

      def payload(user)
        authorization = ManagementAuthorization.new(user)
        credentials = authorization.visible_scope.includes(:created_by, :owner_user).order(revoked_at: :asc, updated_at: :desc, id: :desc)
        ManagementPayload.new(user: user, credentials: credentials).as_json
      end

      def json_text(value) = self.class.text(JSON.generate(value))
      def value_or_dash(value) = value.to_s.strip.presence || "-"
    end
  end
end
