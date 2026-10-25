class HandleRegistry
  HANDLE_MAX_LENGTH = 32

  class << self
    def claim!(handle:, owner:)
      Handle.create!(handle: normalize(handle), owner: owner).tap { owner.association(:handle_record).reset }
    end

    def claim_generated!(owner:, source: nil)
      raise ArgumentError, "owner already has a handle" if Handle.exists?(owner: owner)

      base = generated_base(source || source_for(owner))
      suffix = nil
      loop do
        return Handle.create!(handle: with_suffix(base, suffix), owner: owner).tap { owner.association(:handle_record).reset }
      rescue ActiveRecord::RecordNotUnique
        return claimed_handle(owner) if Handle.exists?(owner: owner)

        suffix = suffix ? suffix + 1 : 2
      rescue ActiveRecord::RecordInvalid => error
        return claimed_handle(owner) if Handle.exists?(owner: owner)
        raise unless error.record.errors.of_kind?(:handle, :taken)

        suffix = suffix ? suffix + 1 : 2
      end
    end

    def rename!(owner:, handle:)
      record = Handle.find_by!(owner: owner)
      record.with_lock { record.update!(handle: normalize(handle)) }
      record
    end

    def release!(owner:)
      Handle.find_by(owner: owner)&.destroy!
      owner.association(:handle_record).reset
    end

    def normalize(value) = value.to_s.downcase.strip

    private

    def claimed_handle(owner)
      Handle.find_by!(owner: owner).tap { owner.association(:handle_record).reset }
    end

    def source_for(owner)
      return owner.github_handle if owner.respond_to?(:github_handle) && owner.github_handle.present?

      owner.email_address.to_s.split("@", 2).first
    end

    def generated_base(value)
      normalized = value.to_s.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/\A[-_]+|[-_]+\z/, "")
      normalized = "user" if normalized.length < 3
      normalized.first(HANDLE_MAX_LENGTH)
    end

    def with_suffix(base, number)
      return base unless number

      suffix = "-#{number}"
      "#{base.first(HANDLE_MAX_LENGTH - suffix.length)}#{suffix}"
    end
  end
end
