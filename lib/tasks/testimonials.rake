namespace :testimonials do
  desc "Backfill #thumbnail for existing testimonials whose #media is a video attached before " \
       "Testimonials::GenerateThumbnailJob existed — that job is only enqueued at creation time " \
       "(Api::V1::TestimonialsController#create_manual and Testimonials::DownloadTiktokVideoJob), so " \
       "any video testimonial created earlier never got a thumbnail. Idempotent: skips anyone that " \
       "already has one, safe to re-run."
  task backfill_thumbnails: :environment do
    count = 0

    Testimonial.includes(media_attachment: :blob, thumbnail_attachment: :blob).find_each do |testimonial|
      next unless testimonial.media.attached?
      next unless testimonial.media.content_type.start_with?("video/")
      next if testimonial.thumbnail.attached?

      Testimonials::GenerateThumbnailJob.perform_later(testimonial.id)
      count += 1
    end

    puts "Enqueued GenerateThumbnailJob for #{count} testimonial(s)."
  end
end
