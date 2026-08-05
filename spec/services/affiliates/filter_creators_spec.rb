require "rails_helper"

RSpec.describe Affiliates::FilterCreators do
  let(:tenant) { Tenant.create!(name: "Loja Filtro", slug: "loja-filtro-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }

  def create_creator(open_id, status:, showcase: 0, content: 0)
    channel.affiliate_creators.create!(
      tenant: tenant,
      creator_open_id: open_id,
      collaboration_status: status,
      showcase_product_count: showcase,
      content_product_count: content
    )
  end

  # Deterministic dataset covering every combination the segments care about.
  let!(:accepted_no_content) { create_creator("u_accepted_no_content", status: "NORMAL", showcase: 0, content: 0) }
  let!(:accepted_with_content) { create_creator("u_accepted_with_content", status: "NORMAL", showcase: 3, content: 2) }
  let!(:showcase_no_content_paused) { create_creator("u_showcase_no_content_paused", status: "PAUSED", showcase: 2, content: 0) }
  let!(:paused_no_showcase) { create_creator("u_paused_no_showcase", status: "PAUSED", showcase: 0, content: 0) }
  let!(:no_status) { create_creator("u_no_status", status: nil, showcase: 0, content: 0) }

  def call(params = {})
    described_class.call(tenant: tenant, channel: channel, params: params)
  end

  describe "no filter" do
    it "returns every creator for the tenant/channel" do
      expect(call.to_a).to match_array([ accepted_no_content, accepted_with_content, showcase_no_content_paused, paused_no_showcase, no_status ])
    end
  end

  describe "collaboration_status exact filter (existing behavior, unchanged)" do
    it "still filters by exact collaboration_status" do
      expect(call(collaboration_status: "NORMAL").to_a).to match_array([ accepted_no_content, accepted_with_content ])
    end
  end

  describe "segments: accepted_no_content" do
    it "returns only creators with an active collaboration and zero content posted" do
      expect(call(segments: [ "accepted_no_content" ]).to_a).to eq([ accepted_no_content ])
    end
  end

  describe "segments: showcase_no_content" do
    it "returns creators with a showcased product and zero content, regardless of collaboration_status" do
      expect(call(segments: [ "showcase_no_content" ]).to_a).to eq([ showcase_no_content_paused ])
    end
  end

  describe "segments: inactive_collaboration" do
    it "returns creators whose collaboration_status is not the confirmed active value, including a blank status" do
      expect(call(segments: [ "inactive_collaboration" ]).to_a)
        .to match_array([ showcase_no_content_paused, paused_no_showcase, no_status ])
    end
  end

  describe "combining multiple segments" do
    it "unions the segments with OR — a creator matching any selected segment is included" do
      result = call(segments: [ "accepted_no_content", "showcase_no_content" ])

      expect(result.to_a).to match_array([ accepted_no_content, showcase_no_content_paused ])
    end
  end

  describe "unknown or blank segment values" do
    it "ignores segment keys that are not in the known SEGMENTS list, instead of raising or matching everything" do
      expect(call(segments: [ "not_a_real_segment" ]).to_a)
        .to match_array([ accepted_no_content, accepted_with_content, showcase_no_content_paused, paused_no_showcase, no_status ])
    end
  end

  describe "combining an exact filter with a segment" do
    it "ANDs collaboration_status with the segment OR-group" do
      result = call(collaboration_status: "PAUSED", segments: [ "showcase_no_content" ])

      expect(result.to_a).to eq([ showcase_no_content_paused ])
    end
  end

  describe "q: free-text search" do
    let!(:maria) { channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u_maria", nickname: "Maria Criadora", username: "maria.criadora") }
    let!(:joao) { channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u_joao", nickname: "João Afiliado", username: "joaoafiliado") }

    it "matches by a case-insensitive partial nickname" do
      expect(call(q: "criad").to_a).to eq([ maria ])
    end

    it "matches by a case-insensitive partial username" do
      expect(call(q: "JOAOAFI").to_a).to eq([ joao ])
    end

    it "returns no rows when nothing matches" do
      expect(call(q: "ninguem-com-esse-nome").to_a).to eq([])
    end

    it "is ignored when blank, same as other filters" do
      expect(call(q: "").to_a).to match_array(
        [ accepted_no_content, accepted_with_content, showcase_no_content_paused, paused_no_showcase, no_status, maria, joao ]
      )
    end

    it "combines with an exact filter via AND" do
      channel.affiliate_creators.create!(
        tenant: tenant, creator_open_id: "u_maria_paused", nickname: "Maria Pausada", username: "maria.pausada", collaboration_status: "PAUSED"
      )

      result = call(collaboration_status: "PAUSED", q: "maria")

      expect(result.map(&:username)).to eq([ "maria.pausada" ])
    end

    it "does not break the campaign-creation usage (segment_filter jsonb hash without q)" do
      expect { call({ segments: [ "accepted_no_content" ] }.with_indifferent_access) }.not_to raise_error
    end
  end
end
