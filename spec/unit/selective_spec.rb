# frozen_string_literal: true

RSpec.describe(Dry::Monads::Selective) do
  include Dry::Monads::Result::Mixin
  include Dry::Monads::Task::Mixin
  include Dry::Monads::Lazy::Mixin

  result = Dry::Monads::Result
  task_class = Dry::Monads::Task
  lazy_class = Dry::Monads::Lazy

  describe result do
    describe "#select" do
      it "satisfies the right law by ignoring the alternative" do
        called = false
        alternative = Success(->(_) { called = true; :fallback })

        expect(Success(Success(:ready)).select(alternative)).to eql(Success(:ready))
        expect(called).to be(false)
      end

      it "satisfies the left law by applying the alternative" do
        alternative = Success(->(error) { "fallback:#{error}" })

        expect(Success(Failure(:missing)).select(alternative))
          .to eql(Success("fallback:missing"))
      end

      it "allows a block to return the alternative context" do
        result = Success(Failure(:missing)).select do |error|
          Success("fallback:#{error}")
        end

        expect(result).to eql(Success("fallback:missing"))
      end

      it "short-circuits outer failures without running the alternative" do
        called = false
        alternative = Success(->(_) { called = true })

        expect(Failure(:outer).select(alternative)).to eql(Failure(:outer))
        expect(called).to be(false)
      end

      it "preserves an alternative failure" do
        expect(Success(Failure(:missing)).select(Failure(:down)))
          .to eql(Failure(:down))
      end

      it "rejects a value that is not an encoded Result" do
        expect { Success(:not_a_result).select(Success(->(value) { value })) }
          .to raise_error(TypeError, /Expected Result/)
      end

      it "requires an alternative or block when the encoded value is Failure" do
        expect { Success(Failure(:missing)).select }
          .to raise_error(ArgumentError, /requires an alternative or a block/)
      end
    end

    describe "#branch" do
      it "uses the right operation for Success" do
        right = Success(->(value) { "right:#{value}" })
        left = Success(->(_) { raise })

        expect(Success(Success(:ok)).branch(left, right))
          .to eql(Success("right:ok"))
      end

      it "uses the left operation for Failure" do
        left = Success(->(error) { "left:#{error}" })
        right = Success(->(_) { raise })

        expect(Success(Failure(:missing)).branch(left, right))
          .to eql(Success("left:missing"))
      end

      it "short-circuits outer failures" do
        expect(Failure(:outer).branch(Success(-> { raise }), Success(-> { raise })))
          .to eql(Failure(:outer))
      end
    end
  end

  describe lazy_class do
    subject(:condition) do
      Lazy do
        runs[:condition] += 1
        encoded_choice
      end
    end

    let(:runs) { Hash.new(0) }
    let(:encoded_choice) { Failure(:missing_config) }

    let(:fallback) do
      Lazy do
        ->(error) {
          runs[:fallback] += 1
          "fallback:#{error}"
        }
      end
    end

    describe "task states" do
      it "distinguishes started tasks from deferred tasks" do
        started = task_class.new { 1 }
        deferred = lazy_class.new { 1 }

        expect(started).to be_started
        expect(started).not_to be_deferred
        expect(deferred).not_to be_started
        expect(deferred).to be_deferred
      end
    end

    describe "#select" do
      it "lists possible operations and counts one conditional branch before execution" do
        encoded = condition.select(fallback)

        expect(encoded).to be_a(lazy_class)
        expect(encoded).to be_deferred
        expect(encoded.branch_count).to be(1)
        expect(encoded.possible_operations)
          .to match_array([condition, fallback])
        expect(runs[:condition]).to be(0)
        expect(runs[:fallback]).to be(0)
      end

      it "does not start the fallback when Success contains the value" do
        encoded = Lazy { Success(:ready) }.select(fallback)

        expect(encoded.value!).to be(:ready)
        expect(runs[:fallback]).to be(0)
      end

      it "starts only the fallback when the encoded value is Failure" do
        expect(condition.select(fallback).value!)
          .to eql("fallback:missing_config")
        expect(runs[:condition]).to be(1)
        expect(runs[:fallback]).to be(1)
      end
    end

    describe "#branch" do
      let(:left) do
        Lazy do
          ->(error) {
            runs[:left] += 1
            "left:#{error}"
          }
        end
      end

      let(:right) do
        Lazy do
          ->(value) {
            runs[:right] += 1
            "right:#{value}"
          }
        end
      end

      it "counts two branches and lists all possible operations" do
        encoded = condition.branch(left, right)

        expect(encoded.branch_count).to be(2)
        expect(encoded.possible_operations)
          .to match_array([condition, left, right])
        expect(runs.values_at(:condition, :left, :right)).to eql([0, 0, 0])
      end

      context "when the encoded choice is Success" do
        let(:encoded_choice) { Success(:ready) }

        it "runs only the right branch" do
          expect(condition.branch(left, right).value!).to eql("right:ready")
          expect(runs[:condition]).to be(1)
          expect(runs[:left]).to be(0)
          expect(runs[:right]).to be(1)
        end
      end

      it "runs only the left branch" do
        expect(condition.branch(left, right).value!).to eql("left:missing_config")
        expect(runs[:condition]).to be(1)
        expect(runs[:left]).to be(1)
        expect(runs[:right]).to be(0)
      end
    end

    describe "with started Task decisions" do
      it "keeps a deferred fallback unstarted when the task already has Success" do
        fallback_runs = 0
        fallback = Lazy { ->(_) { fallback_runs += 1 } }
        selected = task_class.pure(Success(:ready)).select(fallback)

        expect(selected).to be_a(task_class)
        expect(selected).to be_started
        expect(fallback).to be_deferred
        expect(selected.value!).to be(:ready)
        expect(fallback_runs).to be(0)
      end

      it "starts a deferred fallback when the started task contains Failure" do
        fallback_runs = 0
        fallback = Lazy { ->(error) { fallback_runs += 1; "fallback:#{error}" } }
        selected = task_class.pure(Failure(:missing)).select(fallback)

        expect(selected).to be_started
        expect(selected.value!).to eql("fallback:missing")
        expect(fallback_runs).to be(1)
      end
    end
  end
end
