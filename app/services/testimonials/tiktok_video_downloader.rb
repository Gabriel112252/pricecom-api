module Testimonials
  # Baixa o vídeo original de um link do TikTok via yt-dlp — não existe
  # endpoint público equivalente ao oEmbed pra pegar o arquivo de vídeo em
  # si, só metadata (ver TiktokOembedFetcher). Usado pelo fluxo de ingestão
  # via link (DownloadTiktokVideoJob): o vídeo baixado é anexado como
  # #media do testimonial — reaproveita o mesmo player que a Fase 2 já tem
  # pra upload manual — e serve de insumo pro GenerateQuoteTextJob extrair
  # um frame (ver FrameExtractor).
  class TiktokVideoDownloader
    YT_DLP_BIN      = ENV.fetch("YT_DLP_BIN", "yt-dlp").freeze
    TIMEOUT_SECONDS = 60
    GENERIC_ERROR   = "não foi possível baixar o vídeo do TikTok".freeze

    def self.call(url)
      new.call(url)
    end

    def call(url)
      Dir.mktmpdir("tiktok-video-") do |dir|
        output_template = File.join(dir, "video.%(ext)s")

        result = ShellCommand.run(
          YT_DLP_BIN, "--no-progress", "--quiet", "--no-warnings",
          "--format", "mp4/bestvideo+bestaudio/best",
          "--merge-output-format", "mp4",
          "--output", output_template,
          url,
          timeout: TIMEOUT_SECONDS
        )

        return failure(result.stderr) unless result.success?

        video_path = Dir.glob(File.join(dir, "video.*")).first
        return failure("arquivo de vídeo não encontrado após o download") unless video_path

        success(File.binread(video_path), content_type_for(video_path))
      end
    end

    private

    def content_type_for(path)
      case File.extname(path).downcase
      when ".webm" then "video/webm"
      when ".mov"  then "video/quicktime"
      else "video/mp4"
      end
    end

    def success(bytes, content_type)
      { success: true, bytes: bytes, content_type: content_type }
    end

    def failure(detail)
      Rails.logger.warn("Testimonials::TiktokVideoDownloader falhou: #{detail}")
      { success: false, error: GENERIC_ERROR }
    end
  end
end
