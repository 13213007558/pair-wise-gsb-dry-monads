# frozen_string_literal: true

RSpec.describe(Dry::Monads::DelimitedContinuation) do
  subject(:cont) { Dry::Monads::DelimitedContinuation }

  describe ".reset" do
    it "returns the block value when no shift happens" do
      expect(cont.reset { 1 + 2 }).to eql(3)
    end

    it "requires a block" do
      expect { cont.reset }.to raise_error(ArgumentError, /reset requires a block/)
    end

    it "reraises exceptions from the body" do
      expect { cont.reset { raise "boom" } }.to raise_error(RuntimeError, "boom")
    end
  end

  describe ".shift" do
    it "requires a block" do
      expect {
        cont.reset { cont.shift }
      }.to raise_error(ArgumentError, /shift requires a block/)
    end

    it "cannot capture outside of reset" do
      expect { cont.shift { |_k| } }.to raise_error(
        Dry::Monads::DelimitedContinuation::ShiftOutsideResetError,
        /outside of its reset/
      )
    end

    it "cannot capture from a shift handler running outside the reset body" do
      expect {
        cont.reset { cont.shift { |_k| cont.shift { |_inner| } } }
      }.to raise_error(Dry::Monads::DelimitedContinuation::ShiftOutsideResetError)
    end
  end

  describe "early exit" do
    it "uses the handler value as the result and skips the rest of the body" do
      reached = false

      result = cont.reset do
        cont.shift { |_k| :early_exit }
        reached = true
        :unreachable
      end

      expect(result).to be(:early_exit)
      expect(reached).to be(false)
    end
  end

  describe "requesting a value from the outside" do
    it "resumes the computation with the provided value" do
      inputs = ["Alice"]

      greeting = cont.reset do
        name = cont.shift { |k| k.call(inputs.shift) }
        "Hello, #{name}!"
      end

      expect(greeting).to eql("Hello, Alice!")
    end

    it "distinguishes the handler return value from the final value after resumption" do
      result = cont.reset do
        x = cont.shift { |k| k.call(1); :handler_return }
        x + 1
      end

      expect(result).to eql(2)
    end

    it "supports multiple shifts in one reset" do
      result = cont.reset do
        a = cont.shift { |k| k.call(1) }
        b = cont.shift { |k| k.call(2) }
        a + b
      end

      expect(result).to eql(3)
    end
  end

  describe "nested reset" do
    it "captures only up to the nearest enclosing reset" do
      result = cont.reset do
        inner = cont.reset do
          1 + cont.shift { |k| k.call(2) }
        end
        inner * 10
      end

      expect(result).to eql(30)
    end

    it "aborts only the innermost computation when the handler does not resume" do
      result = cont.reset do
        inner = cont.reset do
          cont.shift { |_k| 5 }
          100
        end
        inner + 1
      end

      expect(result).to eql(6)
    end
  end

  describe "single-shot resumption" do
    it "raises when the continuation is resumed twice" do
      expect {
        cont.reset do
          cont.shift { |k| k.call(1); k.call(2) }
        end
      }.to raise_error(
        Dry::Monads::DelimitedContinuation::ContinuationAlreadyResumedError,
        /single-shot/
      )
    end

    it "raises when the continuation escapes the dynamic scope of its reset" do
      escaped = nil

      cont.reset do
        cont.shift { |k| escaped = k }
      end

      expect { escaped.call(1) }.to raise_error(
        Dry::Monads::DelimitedContinuation::ContinuationExpiredError,
        /escaped the dynamic scope/
      )
    end

    it "raises when the continuation is resumed from another thread" do
      escaped = nil

      cont.reset do
        cont.shift { |k| escaped = k }
      end

      thread = Thread.new { escaped.call(1) }
      thread.report_on_exception = false

      expect { thread.value }.to raise_error(
        Dry::Monads::DelimitedContinuation::CrossThreadResumeError,
        /thread/
      )
    end
  end

  describe "ensure execution order" do
    let(:events) { [] }

    def run_with_ensures(&body)
      cont.reset do
        begin
          instance_eval(&body)
        ensure
          events << :inner_ensure
        end
      end
    ensure
      events << :outer_ensure
    end

    it "runs ensures inside-out when the continuation is resumed" do
      run_with_ensures do
        cont.shift { |k| events << :handler; k.call(nil) }
      end

      expect(events).to eql(%i[handler inner_ensure outer_ensure])
    end

    it "runs ensures inside-out when the continuation is abandoned" do
      run_with_ensures do
        cont.shift { |_k| events << :handler }
      end

      expect(events).to eql(%i[handler inner_ensure outer_ensure])
    end

    it "runs ensures inside-out when the body raises" do
      expect {
        run_with_ensures { raise "boom" }
      }.to raise_error(RuntimeError, "boom")

      expect(events).to eql(%i[inner_ensure outer_ensure])
    end
  end
end
