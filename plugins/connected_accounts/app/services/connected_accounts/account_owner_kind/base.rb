module ConnectedAccounts
  module AccountOwnerKind
    class Base
      def self.for(kind)
        { "user" => User, "instance" => Instance }.fetch(kind.to_s).new
      end

      def validate_account(_account); end
      def validate_credential(_account, _credential); end
      def validate_access!(_account, _context) = raise NotImplementedError
      def system_access? = false
      def visible_to?(_account, _user) = false
    end
  end
end
