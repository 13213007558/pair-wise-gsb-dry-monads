# frozen_string_literal: true

RSpec.describe(Dry::Monads::ResultT) do
  include Dry::Monads[:result, :result_t, :task, :list, :lazy]

  let(:async) { ResultT(task_mod) }
  let(:branching) { ResultT(list_mod) }
  let(:task_mod) { Dry::Monads::Task }
  let(:list_mod) { Dry::Monads::List }
  let(:result_mod) { Dry::Monads::Result }

  def task(&block)
    Dry::Monads::Task.new(&block)
  end

  describe "Task outer monad" do
    describe "bind/fmap with execution counting" do
      it "runs each lifted task exactly once and threads the inner success value" do
        executions = []
        mutex = Mutex.new
        gate = Queue.new

        fetch_user = task do
          gate.pop
          mutex.synchronize { executions << :fetch_user }
          Hash[id: 42, name: "leo"]
        end
        save = ->(user) do
          task do
            mutex.synchronize { executions << :save }
            user.merge(saved: true)
          end
        end

        chained = async
                  .lift(fetch_user.fmap { Success(_1) })
                  .bind { |user| async.lift(save.(user).fmap { Success(_1) }) }
                  .fmap { |user| user[:name] }
                  .run

        # While the first task is still pending no later task has started.
        sleep(0.05)
        expect(executions).to eq([])

        gate << :go
        result = chained.wait.value!

        expect(result).to eql(Success("leo"))
        expect(executions).to eq(%i[fetch_user save])

        # Waiting again does not re-run anything.
        chained.wait
        expect(executions).to eq(%i[fetch_user save])
      end

      it "short-circuits on an inner Failure without executing later steps" do
        later_calls = 0

        chained = async
                  .pure(1)
                  .bind { |n| async.failure([:too_big, n]) }
                  .fmap { later_calls += 1 }
                  .bind { later_calls += 1; async.pure(:never) }
                  .run
                  .wait

        expect(chained.value!).to eql(Failure([:too_big, 1]))
        expect(later_calls).to be(0)
        expect(chained).to be_a(task_mod)
      end

      it "keeps a task-raised exception on the Task channel, distinct from Failure" do
        error = StandardError.new("boom")
        later_calls = 0

        chained = async
                  .lift(task { raise error })
                  .bind { later_calls += 1; async.pure(1) }
                  .run
                  .wait

        expect { chained.value! }.to raise_error(error)
        expect(later_calls).to be(0)
      end

      it "does not re-execute an already completed task reused in a nested chain" do
        runs = 0
        mutex = Mutex.new
        existing = task do
          mutex.synchronize { runs += 1 }
          5
        end.wait

        chained = async
                  .lift(existing.fmap { Success(_1) })
                  .bind { |x| async.lift(existing.fmap { Success(x + 1) }) }
                  .fmap { |x| x * 2 }
                  .run
                  .wait

        expect(chained.value!).to eql(Success(12))
        expect(runs).to be(1)
      end

      it "does not force a Lazy while composing" do
        runs = 0
        lazy = Lazy { runs += 1; 7 }

        chained = async
                  .lift(lazy.fmap { Success(_1) })
                  .bind { |x| async.pure(x + 100) }
                  .fmap(&:succ)

        expect(lazy).not_to be_evaluated
        expect(runs).to be(0)

        expect(chained.run.value!).to eql(Success(108))
        expect(lazy).to be_evaluated
        expect(runs).to be(1)
      end
    end

    describe "pure / lift / run" do
      it "wraps plain values with a fulfilled task carrying Success" do
        lifted = async.pure(2).run.wait
        expect(lifted.value!).to eql(Success(2))
        expect(lifted).to be_complete
      end

      it "lifts Task<Result> and retrieves the raw outer value with run" do
        raw = task_mod.pure(Failure(:oops))
        expect(async.lift(raw).run).to equal(raw)
      end

      it "exposes the bound outer monad without guessing it from values" do
        expect(async.monad).to be(described_class)
        expect(async.outer).to be(task_mod)
        expect(branching.outer).to be(list_mod)
      end
    end
  end

  describe "List outer monad" do
    describe "bind with multiple failure branches" do
      it "fans computations out and keeps every branch, including failures" do
        divisions = branching
                     .lift(list_mod[Success(10), Success(20), Success(0)])
                     .bind do |n|
                       branching.lift(list_mod[
                         n.zero? ? Failure(:zero) : Success(n / 2),
                         n.zero? ? Failure(:still_zero) : Success(n / 5)
                       ])
                     end
                     .run

        expect(divisions).to eql(list_mod.new(
          [Success(5), Success(2),
           Success(10), Success(4),
           Failure(:zero), Failure(:still_zero)],
          result_mod
        ))
        expect(divisions).to be_a(list_mod)
        expect(divisions.value.select(&:failure?).size).to be(2)
      end

      it "short-circuits each failing branch independently without dropping others" do
        result = branching
                 .lift(list_mod[Success(1), Failure(:a), Success(2), Failure(:b)])
                 .fmap { |x| x + 10 }
                 .bind { |x| x == 11 ? branching.failure(:boom) : branching.pure(x) }
                 .run

        expect(result).to eql(list_mod.new(
          [Failure(:boom), Failure(:a), Success(12), Failure(:b)],
          result_mod
        ))
      end

      it "keeps an empty list empty" do
        expect(branching.lift(list_mod::Result[]).bind { raise }.run)
          .to eql(list_mod.new([], Dry::Monads::Result))
      end
    end

    describe "pure / lift / run" do
      it "wraps values as List<Result>" do
        expect(branching.pure(3).run).to eql(list_mod.new([Success(3)], Dry::Monads::Result))
        expect(branching.lift(list_mod[Success(3)]).run)
          .to eql(list_mod.new([Success(3)], Dry::Monads::Result))
      end

      it "returns the raw list from run" do
        raw = list_mod.new([Success(1), Failure(:x)], Dry::Monads::Result)
        expect(branching.lift(raw).run).to eql(raw)
      end
    end
  end

  describe "builder construction" do
    it "rejects outer values without a pure operation" do
      expect { ResultT(:not_a_monad) }
        .to raise_error(ArgumentError, /not_a_monad/)
    end

    it "is usable through Dry::Monads.ResultT and the result_t mixin" do
      expect(Dry::Monads.ResultT(task_mod).outer).to be(task_mod)
      expect(ResultT(list_mod).outer).to be(list_mod)
    end

    it "has an informative inspect" do
      expect(branching.pure(1).inspect).to include("ResultT(")
    end
  end

  describe "callable (non-block) form" do
    it "accepts a proc for fmap and bind" do
      increment = ->(x) { x + 1 }
      step = ->(x) { async.pure(x * 10) }

      expect(async.pure(2).fmap(increment).bind(step).run.wait.value!)
        .to eql(Success(30))

      expect(
        branching.lift(list_mod[Success(1), Failure(:e)]).fmap(increment).run
      ).to eql(list_mod.new([Success(2), Failure(:e)], result_mod))
    end
  end
end
