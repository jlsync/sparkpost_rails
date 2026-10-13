require 'spec_helper'

describe SparkPostRails::DeliveryMethod do

  before(:each) do
    SparkPostRails.configuration.set_defaults
    @delivery_method = SparkPostRails::DeliveryMethod.new
  end

  context "Inline Content" do
    it "sets the subject" do
      test_email = Mailer.test_email
      @delivery_method.deliver!(test_email)

      expect(@delivery_method.data[:content][:subject]).to eq("Test Email")
    end

    it "handles single part content" do
      test_email = Mailer.test_email
      @delivery_method.deliver!(test_email)

      expect(@delivery_method.data[:content][:text]).to eq("Hello, Testing!")
      expect(@delivery_method.data[:content].has_key?(:html)).to eq(false)
    end

    it "handles multi-part content" do
      test_email = Mailer.test_email html_part: "<h1>Hello, Testing!</h1>"
      @delivery_method.deliver!(test_email)

      expect(@delivery_method.data[:content][:text]).to eq("Hello, Testing!")
      expect(@delivery_method.data[:content][:html]).to eq("<h1>Hello, Testing!</h1>")
    end

    it "supports HTML-only content as a configuration setting" do
      SparkPostRails.configure do |c|
        c.html_content_only = true
      end

      test_email = Mailer.test_email
      @delivery_method.deliver!(test_email)

      expect(@delivery_method.data[:content].has_key?(:text)).to eq(false)
      expect(@delivery_method.data[:content][:html]).to eq("Hello, Testing!")
    end

    it "supports HTML-only content as an option on an individual transmission" do
      test_email = Mailer.test_email sparkpost_data: {html_content_only: true}
      @delivery_method.deliver!(test_email)

      expect(@delivery_method.data[:content].has_key?(:text)).to eq(false)
      expect(@delivery_method.data[:content][:html]).to eq("Hello, Testing!")
    end

    it "should not include template details" do
      test_email = Mailer.test_email
      @delivery_method.deliver!(test_email)

      expect(@delivery_method.data[:content].has_key?(:template_id)).to eq(false)
      expect(@delivery_method.data[:content].has_key?(:use_draft_template)).to eq(false)
    end
  end

  context "Inline content reconstructed from MIME" do
    def reconstruct_message(original)
      Mail.new(original.encoded).tap do |message|
        message.singleton_class.class_eval { attr_accessor :sparkpost_data }
        message.sparkpost_data = original.respond_to?(:sparkpost_data) ? original.sparkpost_data : {}
      end
    end

    def expect_json_content(expected)
      uri = URI.join(SparkPostRails.configuration.api_endpoint, 'v1/transmissions')
      expect(a_request(:post, uri.to_s).with { |request|
        content = JSON.parse(request.body)["content"]
        expected.all? { |key, value| content[key] == value }
      }).to have_been_made.once
    end

    ["Hello, Testing!", "Café", "Follow us on 𝕏", "Hello 😀"].each do |text|
      it "preserves #{text.inspect} in the JSON request" do
        original = Mailer.test_email text_part: text
        test_email = reconstruct_message(original)

        @delivery_method.deliver!(test_email)

        expect_json_content("text" => text)
      end
    end

    {
      "quoted-printable" => "Caf=C3=A9 =F0=9D=95=8F =F0=9F=98=80",
      "base64" => "Q2Fmw6kg8J2VjyDwn5iA"
    }.each do |transfer_encoding, encoded_body|
      it "decodes #{transfer_encoding} before preserving Unicode in the JSON request" do
        original = Mailer.test_email
        original.body = encoded_body
        original.content_transfer_encoding = transfer_encoding
        test_email = reconstruct_message(original)

        @delivery_method.deliver!(test_email)

        expect_json_content("text" => "Café 𝕏 😀")
      end
    end

    it "transcodes a declared ISO-8859-1 charset to UTF-8" do
      original = Mailer.test_email
      original.content_type = "text/plain; charset=ISO-8859-1"
      original.body = "Café".encode("ISO-8859-1")
      test_email = reconstruct_message(original)

      @delivery_method.deliver!(test_email)

      expect_json_content("text" => "Café")
    end

    ["configuration", "transmission option"].each do |setting|
      it "preserves Unicode in HTML-only delivery using the #{setting}" do
        options = {text_part: "<footer>Café 𝕏 😀</footer>"}
        if setting == "configuration"
          SparkPostRails.configuration.html_content_only = true
        else
          options[:sparkpost_data] = {html_content_only: true, metadata: {source: "mime"}}
        end
        original = Mailer.test_email options
        original.content_type = "text/html; charset=UTF-8"
        test_email = reconstruct_message(original)

        @delivery_method.deliver!(test_email)

        expect_json_content("html" => "<footer>Café 𝕏 😀</footer>", "text" => nil)
        if setting == "transmission option"
          uri = URI.join(SparkPostRails.configuration.api_endpoint, 'v1/transmissions')
          expect(a_request(:post, uri.to_s).with { |request|
            JSON.parse(request.body)["metadata"] == {"source" => "mime"}
          }).to have_been_made.once
        end
      end
    end

    it "uses each multipart body's charset instead of the enclosing message's charset" do
      original = Mailer.test_email text_part: "Café", html_part: "<p>𝕏 😀</p>"
      original.text_part.content_type = "text/plain; charset=ISO-8859-1"
      original.text_part.body = "Café".encode("ISO-8859-1")
      test_email = reconstruct_message(original)

      @delivery_method.deliver!(test_email)

      expect_json_content("text" => "Café", "html" => "<p>𝕏 😀</p>")
    end

    it "transcodes a legacy charset on the HTML part" do
      original = Mailer.test_email text_part: "𝕏 😀", html_part: "<p>Café</p>"
      original.html_part.content_type = "text/html; charset=ISO-8859-1"
      original.html_part.body = "<p>Café</p>".encode("ISO-8859-1")
      test_email = reconstruct_message(original)

      @delivery_method.deliver!(test_email)

      expect_json_content("text" => "𝕏 😀", "html" => "<p>Café</p>")
    end

    ["Hello, Testing!", "Café 𝕏 😀"].each do |text|
      it "assumes UTF-8 for #{text.inspect} when the MIME charset is missing" do
        original = Mailer.test_email
        original.charset = nil
        original.content_type = "text/plain"
        original.body = [text].pack("M")
        original.content_transfer_encoding = "quoted-printable"
        test_email = reconstruct_message(original)
        expect(test_email.charset).to be_nil

        @delivery_method.deliver!(test_email)

        expect_json_content("text" => text)
        expect(test_email.charset).to be_nil
      end
    end

    it "assumes UTF-8 for a multipart body without a charset" do
      original = Mailer.test_email text_part: "Café", html_part: "<p>𝕏 😀</p>"
      original.text_part.charset = nil
      original.text_part.content_type = "text/plain"
      test_email = reconstruct_message(original)
      expect(test_email.text_part.charset).to be_nil

      @delivery_method.deliver!(test_email)

      expect_json_content("text" => "Café", "html" => "<p>𝕏 😀</p>")
      expect(test_email.text_part.charset).to be_nil
    end

    ["UTF-8", nil].each do |charset|
      it "rejects invalid UTF-8 bytes with #{charset.inspect} charset without sending a request" do
        content_type = charset ? "text/plain; charset=#{charset}" : "text/plain"
        original = Mail.new("From: from@example.com\r\nTo: to@example.com\r\n" \
          "Content-Type: #{content_type}\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n=FF")
        original.charset = nil unless charset
        test_email = reconstruct_message(original)
        source = test_email.body.raw_source.dup

        expect { @delivery_method.deliver!(test_email) }.to raise_error(JSON::GeneratorError)

        expect(test_email.body.raw_source).to eq(source)
        uri = URI.join(SparkPostRails.configuration.api_endpoint, 'v1/transmissions')
        expect(a_request(:post, uri.to_s)).not_to have_been_made
      end
    end

    it "rejects bytes invalid for the declared charset without replacing them" do
      original = Mail.new("From: from@example.com\r\nTo: to@example.com\r\n" \
        "Content-Type: text/plain; charset=US-ASCII\r\n" \
        "Content-Transfer-Encoding: quoted-printable\r\n\r\n=FF")
      test_email = reconstruct_message(original)

      expect { @delivery_method.deliver!(test_email) }.to raise_error(Encoding::InvalidByteSequenceError)

      uri = URI.join(SparkPostRails.configuration.api_endpoint, 'v1/transmissions')
      expect(a_request(:post, uri.to_s)).not_to have_been_made
    end

    it "preserves the original bodies, their encodings, and MIME headers" do
      original = Mailer.test_email text_part: "Café", html_part: "<p>𝕏 😀</p>"
      original.text_part.content_type = "text/plain; charset=ISO-8859-1"
      original.text_part.body = "Café".encode("ISO-8859-1")
      test_email = reconstruct_message(original)
      messages = [original, test_email].flat_map { |message| [message, *message.parts] }
      sources = messages.map { |message| message.body.raw_source.dup }
      headers = messages.map { |message| message.header.to_s }

      @delivery_method.deliver!(test_email)

      messages.each_with_index do |message, index|
        expect(message.body.raw_source).to eq(sources[index])
        expect(message.body.raw_source.encoding).to eq(sources[index].encoding)
        expect(message.header.to_s).to eq(headers[index])
      end
      expect_json_content("text" => "Café", "html" => "<p>𝕏 😀</p>")
    end

    it "preserves binary attachments and inline images alongside Unicode bodies" do
      original = Mailer.test_email text_part: "Café 𝕏 😀", html_part: "<p>Café 𝕏 😀</p>"
      original.attachments["file.bin"] = {mime_type: "application/octet-stream", content: "\x00\xFF\xF0".b}
      original.attachments.inline["image.png"] = {mime_type: "image/png", content: "\x89PNG\xFF".b}
      test_email = reconstruct_message(original)
      image = test_email.attachments["image.png"]

      @delivery_method.deliver!(test_email)

      expect_json_content(
        "text" => "Café 𝕏 😀",
        "html" => "<p>Café 𝕏 😀</p>",
        "attachments" => [{"name" => "file.bin", "type" => "application/octet-stream", "data" => "AP/w"}],
        "inline_images" => [{"name" => image.cid, "type" => "image/png", "data" => "iVBOR/8="}]
      )
    end
  end
end

