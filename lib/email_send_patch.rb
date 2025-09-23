require 'pathname'

class EmailSendPatch
  def self.delivering_email(message)
    text_part = message.text_part
    html_part = message.html_part

    return unless html_part

    related = Mail::Part.new
    related.content_type = 'multipart/related'
    related.add_part html_part

    html_body = html_part.body.to_s
    html_body.gsub!(/<body[^>]*>/, "\\0 ")
    html_body.gsub!(/srcset="*"/, "")

    html_body.gsub!(FIND_IMG_SRC_PATTERN) do
      before_src = $1
      image_url = $2  # intenal path, starting from /attachments/...
      after_src = $3

      attachment_object = nil
      attachment_id = nil

      # etraxt attachment-id from download or thumbnail
      if image_url =~ %r{^/attachments/(?:download|thumbnail)/(\d+)}
        attachment_id = $1.to_i
        attachment_object = Attachment.where(id: attachment_id).first
      end

      if attachment_object
        basename = File.basename(attachment_object.filename, ".*")
        extname = File.extname(attachment_object.filename)

        match_thumbnail = image_url.match(%r{/attachments/thumbnail/\d+/(\d+)$})
        if match_thumbnail
          thumbnail_size = match_thumbnail[1].to_i
          image_name = "#{basename}_#{attachment_id}_#{thumbnail_size}#{extname}"
          image_path = attachment_object.thumbnail({size: thumbnail_size})
        else
          image_name = "#{basename}_#{attachment_id}#{extname}"
          image_path = attachment_object.diskfile
        end

        if related.attachments[image_name]
          attachment_url = related.attachments[image_name].url
        else
          if image_path && File.exist?(image_path)
            related.attachments.inline[image_name] = File.binread(image_path)
            attachment_url = related.attachments[image_name].url
          end
        end

        before_src + attachment_url + after_src
      else
        # if attachment not found, leave url unchanged
        before_src + image_url + after_src
      end
    end

    html_part.body = html_body

    # setup multipart/alternative correctly
    alt_parts = message.parts
    message.parts.each do |part|
      if part.content_type.starts_with?('multipart/alternative')
        alt_parts = part.parts
        break
      end
    end

    alt_parts.clear
    alt_parts << text_part
    alt_parts << related
  end
end

ActionMailer::Base.register_interceptor(EmailSendPatch)
