# frozen_string_literal: true
require 'minitest/autorun'
require 'ostruct'
require 'tempfile'
# Rails provides this alias in production.
class String
  alias starts_with? start_with?
end
module Setting
  def self.protocol; 'https'; end
  def self.host_name; 'redmine.example'; end
end
module Redmine
  module Utils
    def self.relative_url_root; ''; end
  end
end
module ActionMailer
  class Base
    def self.register_interceptor(*); end
  end
end
class User
  def self.find_by_mail(address); address == 'allowed@example.com' ? :allowed : nil; end
end
require_relative '../lib/email_send_patch'
class EmailSendPatchTest < Minitest::Test
  def test_external_urls_never_resolve_an_attachment
    %w[https://avatars.slack-edge.com/2025-03-11/avatar.png https://external.example/23331/photo.png https://external.example/attachments/download/23331/a.png //external.example/attachments/download/23331/a.png].each do |url|
      assert_nil EmailSendPatch.attachment_reference(url)
    end
  end
  def test_exact_local_routes
    assert_equal [23331,nil], EmailSendPatch.attachment_reference('/attachments/download/23331/a.png')
    assert_equal [23331,nil], EmailSendPatch.attachment_reference('/attachments/download/23331')
    assert_equal [23331,300], EmailSendPatch.attachment_reference('https://redmine.example/attachments/thumbnail/23331/300')
  end
  def test_invalid_routes
    %w[/2025-03-11/avatar.png /attachments/download/2025-03-11/a.png /attachments/download/0/a.png /attachments/download/1/a.png?x=1 https://redmine.example:444/attachments/download/1/a.png http://redmine.example/attachments/download/1/a.png /attachments/download/1/../../a.png].each do |url|
      assert_nil EmailSendPatch.attachment_reference(url)
    end
  end
  def test_all_recipient_fields_are_checked
    User.stub(:find_by_mail, ->(a) { a == 'allowed@example.com' ? OpenStruct.new(active?:true) : nil }) do
      assert_equal 1, EmailSendPatch.recipient_users(OpenStruct.new(to:['allowed@example.com'],cc:nil,bcc:nil)).length
      assert_empty EmailSendPatch.recipient_users(OpenStruct.new(to:['allowed@example.com'],cc:nil,bcc:['unknown@example.com']))
    end
  end
  def test_no_recipient_keeps_original_message
    message = OpenStruct.new(html_part:OpenStruct.new(body:'original'),to:[],cc:nil,bcc:nil)
    EmailSendPatch.delivering_email(message)
    assert_equal 'original',message.html_part.body
  end
end

# Run MIME integration checks when the Mail gem is available.
begin
  require 'mail'
  class Attachment
    def self.where(*); end
  end
  class EmailSendPatchMimeTest < Minitest::Test
    def setup
      @file = Tempfile.new(['mail-image','.png'])
      @file.binmode
      @file.write("\x89PNG\r\n\x1a\n".b)
      @file.flush
      @user = OpenStruct.new(active?:true)
      @attachment = OpenStruct.new(filename:'image.png',diskfile:@file.path,image?:true)
      def @attachment.visible?(user); true; end
    end
    def teardown
      @file.close!
    end
    def build_message(source)
      Mail.new do
        to 'allowed@example.com'
        text_part { body 'Text' }
        html_part { content_type 'text/html; charset=UTF-8'; body %(<img src="#{source}">) }
      end
    end
    def process(mail)
      User.stub(:find_by_mail,@user) { Attachment.stub(:where,[@attachment]) { EmailSendPatch.delivering_email(mail) } }
      Mail.read_from_string(mail.encoded)
    end
    def test_local_image_embedded_and_text_preserved
      mail=process(build_message('/attachments/download/23/image.png'))
      assert_equal ['image_23.png'],mail.attachments.map(&:filename).sort
      assert_includes mail.all_parts.find{|p|p.mime_type=='text/html'}.body.decoded,'cid:'
      assert_equal 'Text',mail.all_parts.find{|p|p.mime_type=='text/plain'}.body.decoded
    end
    def test_external_image_cannot_trigger_attachment_lookup
      mail=build_message('https://avatars.slack-edge.com/2025-03-11/avatar.png')
      User.stub(:find_by_mail,@user) do
        Attachment.stub(:where,->(*){flunk 'External URL performed an attachment lookup'}) { EmailSendPatch.delivering_email(mail) }
      end
      assert_equal [],mail.attachments.map(&:filename)
      assert_includes mail.all_parts.find{|p|p.mime_type=='text/html'}.body.decoded,'avatars.slack-edge.com'
    end
    def test_non_image_is_not_embedded
      def @attachment.image?; false; end
      assert_equal [],process(build_message('/attachments/download/23/file.zip')).attachments.map(&:filename)
    end
    def test_inaccessible_image_is_not_embedded
      def @attachment.visible?(user); false; end
      assert_equal [],process(build_message('/attachments/download/23/image.png')).attachments.map(&:filename)
    end
  end
rescue LoadError
end
