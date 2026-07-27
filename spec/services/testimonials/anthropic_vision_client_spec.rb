require "rails_helper"

RSpec.describe Testimonials::AnthropicVisionClient do
  let(:image_bytes) { "fake-jpeg-bytes" }
  let(:content_type) { "image/jpeg" }

  around do |example|
    original_key = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-test-key"
    example.run
    ENV["ANTHROPIC_API_KEY"] = original_key
  end

  def stub_messages(status:, body:)
    stub_request(:post, "https://api.anthropic.com/v1/messages").to_return(
      status: status,
      headers: { "Content-Type" => "application/json" },
      body: body.to_json
    )
  end

  describe ".call" do
    it "returns the generated quote text on success" do
      stub_messages(
        status: 200,
        body: {
          id: "msg_1", type: "message", role: "assistant", model: "claude-opus-5",
          content: [ { type: "text", text: "  Esse produto mudou minha rotina!  " } ],
          stop_reason: "end_turn", stop_sequence: nil,
          usage: { input_tokens: 10, output_tokens: 5 }
        }
      )

      result = described_class.call(image_bytes, content_type)

      expect(result).to eq("Esse produto mudou minha rotina!")
    end

    it "returns nil when the response is a refusal, without raising" do
      stub_messages(
        status: 200,
        body: {
          id: "msg_2", type: "message", role: "assistant", model: "claude-opus-5",
          content: [], stop_reason: "refusal", stop_sequence: nil,
          usage: { input_tokens: 10, output_tokens: 0 }
        }
      )

      expect(described_class.call(image_bytes, content_type)).to be_nil
    end

    it "returns nil (not raise) on an API error such as a rate limit" do
      stub_messages(
        status: 429,
        body: { type: "error", error: { type: "rate_limit_error", message: "slow down" } }
      )

      expect(described_class.call(image_bytes, content_type)).to be_nil
    end

    it "returns nil when the response has no text block" do
      stub_messages(
        status: 200,
        body: {
          id: "msg_3", type: "message", role: "assistant", model: "claude-opus-5",
          content: [], stop_reason: "end_turn", stop_sequence: nil,
          usage: { input_tokens: 10, output_tokens: 0 }
        }
      )

      expect(described_class.call(image_bytes, content_type)).to be_nil
    end

    it "sends the image as base64 and the model as claude-opus-5" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with { |req|
          body = JSON.parse(req.body)
          image_block = body.dig("messages", 0, "content").find { |b| b["type"] == "image" }
          expect(body["model"]).to eq("claude-opus-5")
          expect(image_block["source"]["data"]).to eq(Base64.strict_encode64(image_bytes))
          expect(image_block["source"]["media_type"]).to eq("image/jpeg")
          true
        }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            id: "msg_4", type: "message", role: "assistant", model: "claude-opus-5",
            content: [ { type: "text", text: "ok" } ], stop_reason: "end_turn", stop_sequence: nil,
            usage: { input_tokens: 1, output_tokens: 1 }
          }.to_json
        )

      described_class.call(image_bytes, content_type)
    end
  end
end
