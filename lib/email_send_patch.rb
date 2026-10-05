require 'uri'

class EmailSendPatch
  FIND_IMG_SRC_PATTERN = /(<img\b[^>]*\bsrc=")([^"]+)("[^>]*>)/i

  # Only canonical attachment routes on this Redmine instance may access files.
  def self.attachment_reference(source)
    uri = URI.parse(source)
    return if uri.userinfo || uri.query || uri.fragment
    if uri.host || uri.scheme
      base = URI.parse("#{Setting.protocol}://#{Setting.host_name}")
      return unless %w[http https].include?(uri.scheme) &&
                    uri.scheme == base.scheme && uri.host == base.host && uri.port == base.port
    end
    root = Redmine::Utils.relative_url_root.to_s.sub(%r{/$}, '')
    match = uri.path.match(%r{\A#{Regexp.escape(root)}/attachments/(?:download/(?<id>[1-9]\d*)(?:/[^/]+)?|thumbnail/(?<thumb_id>[1-9]\d*)/(?<size>[1-9]\d*))\z})
    return unless match

    [(match[:id] || match[:thumb_id]).to_i, match[:size]&.to_i]
  rescue URI::InvalidURIError
    nil
  end

  def self.recipient_users(message)
    addresses = [message.to, message.cc, message.bcc].flatten.compact.uniq
    return [] if addresses.empty?

    users = addresses.map { |address| User.find_by_mail(address) }
    return [] unless users.all? { |user| user && user.active? }

    users.uniq
  end

  def self.delivering_email(message)
    text_part = message.text_part
    html_part = message.html_part

    if html_part
      users = recipient_users(message)
      return if users.empty?

      related = Mail::Part.new
      related.content_type = 'multipart/related'
      related.add_part html_part
      html_part.body = html_part.body.to_s.gsub(/<body[^>]*>/, "\\0 ")
      html_part.body = html_part.body.to_s.gsub(/srcset="*"/, "")
      html_part.body = html_part.body.to_s.gsub(EmailSendPatch::FIND_IMG_SRC_PATTERN) do |original|
        before_src = $1
        image_url = $2
        after_src = $3

        reference = attachment_reference(image_url)
        next original unless reference

        attachment_url = image_url
        attachment_id, thumbnail_size = reference
        attachment_object = Attachment.where(:id => attachment_id).first
        next original unless attachment_object && attachment_object.image? &&
                             users.all? { |user| attachment_object.visible?(user) }

        if attachment_object
          basename = File.basename(attachment_object.filename, ".*")
          extname = File.extname(attachment_object.filename)

          # Note: image_name = [basename]_[attachment_id]_[thumbnail_size][extname]
          if thumbnail_size
            image_name = "#{basename}_#{attachment_id}_#{thumbnail_size}#{extname}"
            image_path = attachment_object.thumbnail({size: thumbnail_size})
          else
            image_name = "#{basename}_#{attachment_id}#{extname}"
            image_path = attachment_object.diskfile
          end

          if related.attachments[image_name]
            # Using existing attachment if it was already added
            attachment_url = related.attachments[image_name].url
          else
            if image_path && File.exist?(image_path)
              # Adding inline attachment
              related.attachments.inline[image_name] = File.binread(image_path)
              attachment_url = related.attachments[image_name].url
            end
          end
        end

        before_src << attachment_url << after_src
      end

      alt_parts = message.parts
      message.parts.each do |part|
        if part.content_type.starts_with?('multipart/alternative')
          alt_parts = part.parts
          break
        end
      end

      # multipart/alternative
      # - text/plain
      # - multipart/relative
      # -- text/html
      # -- image/*
      alt_parts.clear
      alt_parts << text_part
      alt_parts << related
    end
  end
end

ActionMailer::Base.register_interceptor(EmailSendPatch)

