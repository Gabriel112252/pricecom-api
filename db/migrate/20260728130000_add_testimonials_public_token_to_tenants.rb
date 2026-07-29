class AddTestimonialsPublicTokenToTenants < ActiveRecord::Migration[7.2]
  def change
    # Same pattern as tv_token (20260710010001_add_tv_token_to_tenants.rb):
    # long, unguessable, the only thing standing between the public
    # /api/public/v1/testimonials route and this tenant's testimonials.
    # NOT the slug — slug is a plain readable identifier, not a secret, and
    # using it here would let anyone enumerate other tenants' published
    # testimonials by guessing slugs.
    add_column :tenants, :testimonials_public_token, :string
    add_index :tenants, :testimonials_public_token, unique: true
  end
end
