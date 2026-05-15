class Credentials::DocumentsController < ApplicationController
  def create
    created = []
    errors = []

    uploaded_files.each do |file|
      document = Current.user.documents.build(kind: "file", user: Current.user)
      document.file.attach(file)
      if document.save
        created << document
      else
        errors.concat(document.errors.full_messages)
      end
    end

    if google_doc_url.present?
      document = Current.user.documents.build(kind: "google_doc", google_doc_url: google_doc_url, user: Current.user)
      if document.save
        created << document
      else
        errors.concat(document.errors.full_messages)
      end
    end

    if created.any? && errors.empty?
      redirect_to edit_credentials_path, notice: "Document added."
    elsif created.any?
      redirect_to edit_credentials_path, alert: "Some documents could not be added: #{errors.to_sentence}"
    else
      redirect_to edit_credentials_path, alert: errors.presence&.to_sentence || "Choose a file or enter a Google Doc URL."
    end
  end

  def destroy
    document = Current.user.documents.find(params[:id])
    document.destroy!
    redirect_to edit_credentials_path, notice: "Document removed."
  end

  private

  def uploaded_files
    Array(params.dig(:document, :files)).compact_blank
  end

  def google_doc_url
    params.dig(:document, :google_doc_url).to_s.strip
  end
end
