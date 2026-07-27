require "rails_helper"

RSpec.describe Testimonials::ShellCommand do
  describe ".run" do
    it "captures stdout and reports success for a command that exits 0" do
      result = described_class.run("echo", "hello", timeout: 5)

      expect(result.success?).to eq(true)
      expect(result.stdout).to eq("hello\n")
    end

    it "captures stderr and reports failure for a command that exits non-zero" do
      result = described_class.run("bash", "-c", "echo oops >&2; exit 1", timeout: 5)

      expect(result.success?).to eq(false)
      expect(result.stderr).to eq("oops\n")
    end

    it "kills the process and reports failure when it exceeds the timeout" do
      started_at = Time.current

      result = described_class.run("sleep", "5", timeout: 0.3)

      expect(result.success?).to eq(false)
      expect(Time.current - started_at).to be < 2 # bem menor que os 5s do sleep — prova que matou o processo
    end

    it "reports failure with a clear message when the binary does not exist" do
      result = described_class.run("this-binary-does-not-exist-anywhere", timeout: 5)

      expect(result.success?).to eq(false)
      expect(result.stderr).to include("comando não encontrado")
    end
  end
end
