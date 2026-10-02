# frozen_string_literal: true

RSpec.describe(Dry::Monads::ResultT) do
  result = Dry::Monads::Result
  success = result::Success.method(:new)
  failure = result::Failure.method(:new)

  task = Dry::Monads::Task
  list = Dry::Monads::List
  lazy = Dry::Monads::Lazy

  result_t = described_class

  def unwrap(monad, transformed)
    value = transformed.to_monad
    monad <= Dry::Monads::Task ? value.value! : value
  end

  describe ".new" do
    it "wraps an outer monad of Result" do
      wrapped = result_t.new(list, list[success.(1)])
      expect(wrapped.to_monad).to eql(list[success.(1)])
    end

    it "rejects values of a different monad instead of guessing the outer type" do
      expect { result_t.new(task, list[success.(1)]) }.to raise_error(TypeError, /cannot wrap/)
      expect { result_t.new(list, task.pure(success.(1))) }.to raise_error(TypeError, /cannot wrap/)
    end
  end

  describe ".pure" do
    it "wraps a value with the outer monad and Success" do
      expect(unwrap(task, result_t.pure(task, 1))).to eql(success.(1))
      expect(result_t.pure(list, 1).to_monad).to eql(list[success.(1)])
    end

    it "wraps a block" do
      fn = -> x { x + 1 }
      expect(unwrap(task, result_t.pure(task, &fn))).to eql(success.(fn))
    end
  end

  describe ".lift" do
    it "wraps every value of the outer monad with Success" do
      expect(unwrap(task, result_t.lift(task, task.new { 5 }))).to eql(success.(5))
      expect(result_t.lift(list, list[1, 2]).to_monad).to eql(list[success.(1), success.(2)])
    end
  end

  describe "#fmap" do
    it "maps over the innermost value" do
      wrapped = result_t.pure(list, 1).fmap { |x| x + 1 }
      expect(wrapped.to_monad).to eql(list[success.(2)])
    end

    it "accepts a callable" do
      wrapped = result_t.pure(list, 1)
      expect(wrapped.fmap(&:inspect)).to eql(wrapped.fmap(:inspect.to_proc))
    end

    it "keeps failures untouched" do
      wrapped = result_t.new(list, list[failure.(:err)]).fmap { |x| x + 1 }
      expect(wrapped.to_monad).to eql(list[failure.(:err)])
    end
  end

  describe "#bind" do
    it "requires the block to return a ResultT over the same outer monad" do
      wrapped = result_t.new(list, list[success.(1)])

      expect { wrapped.bind { success.(2) } }.to raise_error(TypeError, /ResultT/)
      expect { wrapped.bind { |x| result_t.pure(task, x) } }.to raise_error(TypeError, /ResultT/)
    end

    it "accepts a callable" do
      wrapped = result_t.pure(list, 1)
      square = -> x { result_t.pure(list, x * x) }
      expect(wrapped.bind(square)).to eql(wrapped.bind(&square))
    end
  end

  describe "#to_monad" do
    it "returns the raw outer value" do
      inner = task.pure(success.(1))
      expect(result_t.new(task, inner).to_monad).to be(inner)
    end
  end

  context "with Task as the outer monad" do
    it "chains Task<Result> computations and runs every task exactly once" do
      calls = Hash.new(0)

      fetch_user = lambda do |id|
        task[:io] {
          calls[:fetch] += 1
          id.positive? ? success.(id * 10) : failure.(:not_found)
        }
      end
      fetch_account = lambda do |user_id|
        task[:io] {
          calls[:account] += 1
          success.(user_id + 1)
        }
      end

      chained = result_t
        .new(task, fetch_user.(3))
        .bind { |user_id| result_t.new(task, fetch_account.(user_id)) }
        .fmap { |account| account * 2 }

      expect(chained.to_monad.value!).to eql(success.(62))
      expect(calls).to eql(fetch: 1, account: 1)

      # retrieving the outer value again doesn't re-run anything
      expect(chained.to_monad.value!).to eql(success.(62))
      expect(calls).to eql(fetch: 1, account: 1)
    end

    it "keeps a Failure of a completed task on the value channel" do
      chained = result_t
        .new(task, task.pure(failure.(:not_found)))
        .bind { |x| result_t.pure(task, x + 1) }

      # a rejected task would raise here instead of returning a Failure
      expect(chained.to_monad.value!).to eql(failure.(:not_found))
    end

    it "keeps a task's own exception on the rejection channel" do
      chained = result_t
        .new(task, task[:io] { raise "boom" })
        .bind { |x| result_t.pure(task, x + 1) }

      expect { chained.to_monad.value! }.to raise_error(RuntimeError, "boom")
    end
  end

  context "with List as the outer monad" do
    it "keeps every branch when some of them fail" do
      wrapped = result_t.new(
        list,
        list[success.(1), failure.(:e1), success.(3), failure.(:e2)]
      )

      chained = wrapped.bind { |x|
        if x.odd?
          result_t.pure(list, x * 10)
        else
          result_t.new(list, list[failure.(:even)])
        end
      }

      expect(chained.to_monad.value).to eql(
        [success.(10), failure.(:e1), success.(30), failure.(:e2)]
      )
    end

    it "composes nested binds without dropping branches" do
      wrapped = result_t.new(list, list[success.(1), failure.(:e1), success.(2)])

      chained = wrapped
        .bind { |x| result_t.lift(list, list[x, x + 10]) }
        .bind { |x| result_t.pure(list, x * 2) }

      expect(chained.to_monad.value).to eql(
        [success.(2), success.(22), failure.(:e1), success.(4), success.(24)]
      )
    end
  end

  context "with Lazy as the outer monad" do
    it "neither forces nor re-runs the computation while composing" do
      count = 0
      computation = lazy.new { count += 1; success.(1) }

      chained = result_t
        .new(lazy, computation)
        .bind { |x| result_t.pure(lazy, x + 1) }
        .fmap { |x| x * 10 }

      expect(computation).not_to be_evaluated
      expect(count).to be(0)

      expect(chained.to_monad.value!).to eql(success.(20))
      expect(count).to be(1)
    end
  end

  describe "monad laws" do
    # A tiny deterministic property check: for every generated sample
    # the laws must hold for both the Task and List outer monads.
    rng = Random.new(4207)
    ints = Array.new(20) { rng.rand(-100..100) }

    {
      "Task" => [task, -> m { m.value! }],
      "List" => [list, -> m { m.value }]
    }.each do |name, (monad, run)|
      context "over #{name}" do
        let(:pure) { -> x { result_t.pure(monad, x) } }
        let(:f) {
          -> x { x.even? ? pure.(x + 1) : result_t.new(monad, monad.pure(failure.(:odd))) }
        }
        let(:g) {
          -> x { x.abs < 50 ? pure.(x * 2) : result_t.new(monad, monad.pure(failure.(:big))) }
        }

        def equivalent(run, left, right)
          expect(run.(left.to_monad)).to eql(run.(right.to_monad))
        end

        it "satisfies the left identity law: pure(a).bind(f) == f(a)" do
          ints.each do |a|
            equivalent(run, pure.(a).bind { |x| f.(x) }, f.(a))
          end
        end

        it "satisfies the right identity law: m.bind(pure) == m" do
          ints.each do |a|
            [success.(a), failure.(:err)].each do |result|
              m = result_t.new(monad, monad.pure(result))
              equivalent(run, m.bind { |x| pure.(x) }, m)
            end
          end
        end

        it "satisfies the associativity law: m.bind(f).bind(g) == m.bind { |x| f(x).bind(g) }" do
          ints.each do |a|
            [success.(a), failure.(:err)].each do |result|
              m = result_t.new(monad, monad.pure(result))
              left = m.bind { |x| f.(x) }.bind { |x| g.(x) }
              right = m.bind { |x| f.(x).bind { |y| g.(y) } }
              equivalent(run, left, right)
            end
          end
        end
      end
    end
  end
end
