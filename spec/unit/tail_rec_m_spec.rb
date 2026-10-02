# frozen_string_literal: true

RSpec.describe(Dry::Monads::TailRecM) do
  include Dry::Monads[:result, :maybe, :list, :task]

  describe "instruction constructors" do
    it "provides Continue and Done via monad mixins" do
      expect(Continue(1)).to eql(described_class::Continue.new(1))
      expect(Done(1)).to eql(described_class::Done.new(1))
    end

    it "provides Continue and Done on Dry::Monads" do
      expect(Dry::Monads.Continue(1)).to eql(described_class::Continue.new(1))
      expect(Dry::Monads.Done(1)).to eql(described_class::Done.new(1))
    end

    it "supports pattern matching" do
      case Continue(5)
      in Dry::Monads::TailRecM::Continue[state]
        expect(state).to be(5)
      else
        raise "Continue didn't match"
      end

      case Done(6)
      in Dry::Monads::TailRecM::Done[value]
        expect(value).to be(6)
      else
        raise "Done didn't match"
      end
    end
  end

  describe Dry::Monads::Result do
    describe ".tail_rec_m" do
      it "loops until Done without growing the stack" do
        result = described_class.tail_rec_m(0) do |i|
          if i < 100_000
            Success(Continue(i + 1))
          else
            Success(Done(i))
          end
        end

        expect(result).to eql(Success(100_000))
      end

      it "stops on the first Failure and returns it as is" do
        calls = 0
        result = described_class.tail_rec_m(0) do |i|
          calls += 1
          i < 3 ? Success(Continue(i + 1)) : Failure(:boom)
        end

        expect(result).to eql(Failure(:boom))
        expect(calls).to be(4)
      end

      it "returns the Done value as is, even if it looks like an instruction" do
        result = described_class.tail_rec_m(0) do |i|
          Success(Done(Continue(i)))
        end

        expect(result).to eql(Success(Continue(0)))
      end

      it "raises a TypeError when a step returns a plain value" do
        expect {
          described_class.tail_rec_m(0) { |i| Success(i + 1) }
        }.to raise_error(TypeError, /Continue or Done/)
      end

      it "raises a TypeError when the block doesn't return a Result" do
        expect {
          described_class.tail_rec_m(0) { |_| Some(Done(1)) }
        }.to raise_error(TypeError, /must return a Result/)
      end
    end
  end

  describe Dry::Monads::Maybe do
    describe ".tail_rec_m" do
      it "loops until Done without growing the stack" do
        result = described_class.tail_rec_m(0) do |i|
          if i < 100_000
            Some(Continue(i + 1))
          else
            Some(Done(i))
          end
        end

        expect(result).to eql(Some(100_000))
      end

      it "stops on None and returns it as is" do
        calls = 0
        result = described_class.tail_rec_m(0) do |i|
          calls += 1
          i < 3 ? Some(Continue(i + 1)) : None()
        end

        expect(result).to eql(None())
        expect(calls).to be(4)
      end

      it "returns the Done value as is, even if it looks like an instruction" do
        result = described_class.tail_rec_m(0) do |i|
          Some(Done(Continue(i)))
        end

        expect(result).to eql(Some(Continue(0)))
      end

      it "raises a TypeError when a step returns a plain value" do
        expect {
          described_class.tail_rec_m(0) { |i| Some(i + 1) }
        }.to raise_error(TypeError, /Continue or Done/)
      end

      it "raises a TypeError when the block doesn't return a Maybe" do
        expect {
          described_class.tail_rec_m(0) { |_| Success(Done(1)) }
        }.to raise_error(TypeError, /must return a Maybe/)
      end
    end
  end

  describe Dry::Monads::List do
    describe ".tail_rec_m" do
      # Reference implementation: a plain recursive bind, blowing the
      # stack on deep recursions but fine for shallow ones
      def naive_tail_rec_m(f, state)
        f.(state).to_ary.flat_map do |instruction|
          case instruction
          when Dry::Monads::TailRecM::Continue
            naive_tail_rec_m(f, instruction.state)
          when Dry::Monads::TailRecM::Done
            [instruction.value]
          end
        end
      end

      it "expands branches in the same depth-first order as a recursive bind" do
        f = lambda do |i|
          if i < 3
            Dry::Monads::List[Continue(i + 1), Done(i * 10), Continue(i + 1)]
          else
            Dry::Monads::List[Done(i * 10)]
          end
        end

        expect(described_class.tail_rec_m(0, &f)).to eql(List(naive_tail_rec_m(f, 0)))
        expect(described_class.tail_rec_m(0, &f).to_ary).to eql(
          [30, 20, 30, 10, 30, 20, 30, 0, 30, 20, 30, 10, 30, 20, 30]
        )
      end

      it "loops 100_000 steps without growing the stack" do
        result = described_class.tail_rec_m(0) do |i|
          i < 100_000 ? Dry::Monads::List[Continue(i + 1)] : Dry::Monads::List[Done(i)]
        end

        expect(result).to eql(Dry::Monads::List[100_000])
      end

      it "drops branches that produce no instructions" do
        result = described_class.tail_rec_m(0) do |i|
          if i.zero?
            Dry::Monads::List[Continue(1), Done(:skipped)]
          elsif i == 1
            Dry::Monads::List[]
          else
            Dry::Monads::List[Done(i)]
          end
        end

        expect(result).to eql(Dry::Monads::List[:skipped])
      end

      it "emits Done values as is, even if they look like instructions" do
        result = described_class.tail_rec_m(0) do |i|
          Dry::Monads::List[Done(Continue(i))]
        end

        expect(result).to eql(Dry::Monads::List[Continue(0)])
      end

      it "raises a TypeError when a step returns a plain value" do
        expect {
          described_class.tail_rec_m(0) { |_| Dry::Monads::List[:plain] }
        }.to raise_error(TypeError, /Continue or Done/)
      end
    end
  end

  describe Dry::Monads::Task do
    describe ".tail_rec_m" do
      it "loops 100_000 steps without growing the stack" do
        task = described_class.tail_rec_m(0) do |i|
          i < 100_000 ? Dry::Monads::Task.pure(Continue(i + 1)) : Dry::Monads::Task.pure(Done(i))
        end

        task.wait(30)
        expect(task.value!).to be(100_000)
      end

      it "doesn't block the caller while the loop is running" do
        gate = Queue.new
        task = described_class.tail_rec_m(0) do |i|
          Task {
            gate.pop
            Done(i)
          }
        end

        expect(task).not_to be_complete

        gate << :go
        task.wait(5)
        expect(task.value!).to be(0)
      end

      it "doesn't run the loop on the caller's thread" do
        caller_thread = Thread.current
        threads = []
        task = described_class.tail_rec_m(0) do |i|
          threads << Thread.current
          Dry::Monads::Task.pure(Done(i))
        end
        task.wait(5)

        expect(threads).not_to be_empty
        expect(threads).not_to include(caller_thread)
      end

      it "doesn't spawn a thread per step" do
        threads_before = Thread.list.size
        task = described_class.tail_rec_m(0) do |i|
          i < 10_000 ? Dry::Monads::Task.pure(Continue(i + 1)) : Dry::Monads::Task.pure(Done(i))
        end

        task.wait(10)
        expect(task.value!).to be(10_000)
        expect(Thread.list.size - threads_before).to be < 100
      end

      it "stops the loop on a failed step and propagates the error" do
        error = RuntimeError.new("boom")
        calls = 0
        task = described_class.tail_rec_m(0) do |i|
          calls += 1
          i < 3 ? Dry::Monads::Task.pure(Continue(i + 1)) : Dry::Monads::Task.failed(error)
        end

        expect { task.value! }.to raise_error(error)
        expect(calls).to be(4)
      end

      it "fails the task when the block raises" do
        task = described_class.tail_rec_m(0) { |_| raise "boom" }

        expect { task.value! }.to raise_error(RuntimeError, "boom")
      end

      it "fails the task when a step returns a plain value" do
        task = described_class.tail_rec_m(0) { |_| Dry::Monads::Task.pure(:plain) }

        expect { task.value! }.to raise_error(TypeError, /Continue or Done/)
      end

      it "fails the task when the block doesn't return a Task" do
        task = described_class.tail_rec_m(0) { |_| Success(Done(1)) }

        expect { task.value! }.to raise_error(TypeError, /must return a Task/)
      end
    end
  end
end
