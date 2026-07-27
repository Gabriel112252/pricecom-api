module Testimonials
  # Extrai um frame representativo de uma mídia anexada (ActiveStorage) pra
  # enviar como imagem pra API de visão da Anthropic — ela não aceita vídeo
  # direto, só imagem (ver AnthropicVisionClient). Se a mídia já for imagem,
  # devolve os bytes originais sem tocar em ffmpeg.
  class FrameExtractor
    FFMPEG_BIN      = ENV.fetch("FFMPEG_BIN", "ffmpeg").freeze
    TIMEOUT_SECONDS = 30
    # Frame no segundo 1, não no 0 — vídeos de depoimento no TikTok
    # costumam abrir com transição/tela preta/watermark de countdown.
    SEEK_SECONDS = "00:00:01".freeze

    def self.call(attachment)
      new.call(attachment)
    end

    def call(attachment)
      return nil unless attachment.attached?

      content_type = attachment.blob.content_type
      return { bytes: attachment.download, content_type: content_type } if content_type.start_with?("image/")
      return nil unless content_type.start_with?("video/")

      extract_frame(attachment, content_type)
    end

    private

    def extract_frame(attachment, content_type)
      Dir.mktmpdir("frame-extract-") do |dir|
        video_path = File.join(dir, "input#{extension_for(content_type)}")
        File.binwrite(video_path, attachment.download)

        frame_path = File.join(dir, "frame.jpg")
        result = ShellCommand.run(
          FFMPEG_BIN, "-y", "-ss", SEEK_SECONDS, "-i", video_path,
          "-frames:v", "1", "-q:v", "3", frame_path,
          timeout: TIMEOUT_SECONDS
        )

        return nil unless result.success? && File.exist?(frame_path)

        { bytes: File.binread(frame_path), content_type: "image/jpeg" }
      end
    end

    def extension_for(content_type)
      case content_type
      when "video/webm" then ".webm"
      when "video/quicktime" then ".mov"
      else ".mp4"
      end
    end
  end
end
