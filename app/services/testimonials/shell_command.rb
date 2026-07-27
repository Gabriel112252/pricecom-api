module Testimonials
  # Roda um binário externo (yt-dlp/ffmpeg) com timeout de verdade —
  # `Timeout.timeout` sozinho em volta de `Open3.capture3` não mata o
  # processo filho quando estoura, só abandona a thread esperando por ele; o
  # download/transcode continuaria rodando pra sempre em background (o job
  # do Sidekiq nunca mais teria controle sobre esse processo). `pgroup: true`
  # + kill do grupo garante que subprocessos que o yt-dlp/ffmpeg criem (ex.:
  # yt-dlp chama ffmpeg internamente pra mesclar áudio/vídeo) morrem junto.
  module ShellCommand
    Result = Struct.new(:success?, :stdout, :stderr, keyword_init: true)

    def self.run(*cmd, timeout:)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe

      begin
        pid = Process.spawn(*cmd, out: stdout_w, err: stderr_w, pgroup: true)
      rescue Errno::ENOENT
        return Result.new(success?: false, stdout: "", stderr: "#{cmd.first}: comando não encontrado")
      end
      stdout_w.close
      stderr_w.close

      status = wait_with_timeout(pid, timeout)
      Result.new(success?: status&.success? || false, stdout: stdout_r.read, stderr: stderr_r.read)
    ensure
      [ stdout_r, stdout_w, stderr_r, stderr_w ].each { |io| io&.close unless io&.closed? }
    end

    def self.wait_with_timeout(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        return status if status

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          begin
            Process.kill(-9, pid)
          rescue Errno::ESRCH
            nil
          end
          Process.wait(pid)
          return nil
        end

        sleep 0.2
      end
    end
    private_class_method :wait_with_timeout
  end
end
