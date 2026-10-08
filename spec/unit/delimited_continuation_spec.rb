# frozen_string_literal: true

RSpec.describe(Dry::Monads::DelimitedContinuation) do
  subject(:continuation) { described_class }

  def reset(&block) = described_class.reset(&block)

  def shift(&handler) = described_class.shift(&handler)

  describe ".reset" do
    it "returns the block's value when shift is never called" do
      expect(reset { 1 + 2 }).to be(3)
    end

    it "propagates exceptions raised by the block" do
      expect { reset { raise "boom" } }.to raise_error("boom")
    end

    it "supports multiple shifts within a single reset" do
      result = reset do
        first = shift { |k| k.call(1) }
        second = shift { |k| k.call(2) }
        first + second
      end

      expect(result).to be(3)
    end
  end

  describe "handler return value vs resumed final value" do
    it "returns the handler's value when the continuation is not resumed" do
      result = reset do
        1 + shift { 999 }
      end

      expect(result).to be(999)
    end

    it "returns the final value of the computation when resumed, discarding the handler's value" do
      handler_value = nil

      result = reset do
        1 + shift { |k| handler_value = k.call(10) * 100 }
      end

      # k.call(10) resumes the computation: shift evaluates to 10 and the
      # block finishes with 1 + 10 = 11, which is both k's return value
      # and the value of reset. The handler's own 11 * 100 is discarded.
      expect(handler_value).to be(1100)
      expect(result).to be(11)
    end
  end

  describe "nested resets" do
    it "captures only the nearest enclosing reset" do
      result = reset do
        inner = reset do
          shift { :inner_aborted }
          :inner_unreachable
        end

        [inner, :outer_continues]
      end

      expect(result).to eql([:inner_aborted, :outer_continues])
    end

    it "resumes only up to the nearest enclosing reset" do
      result = reset do
        value = reset do
          2 * shift { |k| k.call(3) }
        end

        value + 1
      end

      expect(result).to be(7)
    end
  end

  describe "errors" do
    it "raises UnboundShiftError when shift is called outside of reset" do
      expect { shift { :noop } }.to raise_error(described_class::UnboundShiftError)
    end

    it "raises UnboundShiftError when shift is called from another fiber" do
      error = nil

      reset do
        Fiber.new {
          begin
            shift { :noop }
          rescue described_class::UnboundShiftError => e
            error = e
          end
        }.resume
      end

      expect(error).to be_a(described_class::UnboundShiftError)
    end

    it "raises ContinuationUsedError when a continuation is resumed twice" do
      captured = nil

      reset do
        shift { |k| captured = k; k.call(1) }
      end

      expect { captured.call(2) }.to raise_error(described_class::ContinuationUsedError)
    end

    it "raises ContinuationExpiredError when a continuation escapes its reset" do
      captured = nil

      reset do
        shift { |k| captured = k; :aborted }
      end

      expect { captured.call(1) }.to raise_error(described_class::ContinuationExpiredError)
    end

    it "raises ContinuationExpiredError when a nested reset's continuation is resumed too late" do
      captured = nil

      reset do
        reset do
          shift { |k| captured = k; :inner_aborted }
        end
      end

      expect { captured.call(1) }.to raise_error(described_class::ContinuationExpiredError)
    end

    it "raises CrossThreadContinuationError when resumed from another thread" do
      error = nil

      reset do
        shift do |k|
          Thread.new {
            begin
              k.call(1)
            rescue described_class::CrossThreadContinuationError => e
              error = e
            end
          }.join
        end
      end

      expect(error).to be_a(described_class::CrossThreadContinuationError)
    end
  end

  describe "examples" do
    it "supports early exit" do
      reached = false

      result = reset do
        shift { :early_exit }
        reached = true
      end

      expect(result).to be(:early_exit)
      expect(reached).to be(false)
    end

    it "requests a value from the outside world and resumes with it" do
      mailbox = Queue.new
      producer = Thread.new { mailbox.push("external-value") }

      result = reset do
        received = shift { |k| k.call(mailbox.pop) }
        "got: #{received}"
      end

      producer.join
      expect(result).to eql("got: external-value")
    end
  end

  describe "ensure execution" do
    it "runs ensure clauses after resuming to completion" do
      log = []

      result = reset do
        begin
          shift { |k| log << :handler; k.call(:resumed) }
        ensure
          log << :ensure
        end
      end

      expect(result).to be(:resumed)
      expect(log).to eql(%i[handler ensure])
    end

    it "runs ensure clauses when the handler aborts the computation" do
      log = []

      result = reset do
        begin
          shift { log << :handler; :aborted }
          log << :unreachable
        ensure
          log << :ensure
        end
      end

      expect(result).to be(:aborted)
      expect(log).to eql(%i[handler ensure])
    end

    it "runs ensure clauses when the block raises after being resumed" do
      log = []

      expect {
        reset do
          begin
            shift { |k| log << :handler; k.call(nil) }
            raise "boom"
          ensure
            log << :ensure
          end
        end
      }.to raise_error("boom")

      expect(log).to eql(%i[handler ensure])
    end
  end
end
