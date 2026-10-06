# frozen_string_literal: true

RSpec.describe(Dry::Monads::Free) do
  include Dry::Monads[:free, :result, :task]

  Get = Struct.new(:key)
  Put = Struct.new(:key, :value)

  let(:memory) { { initial: 41 } }
  let(:logs) { [] }

  let(:program) do
    described_class
      .suspend(Get[:initial])
      .bind { |value| described_class.suspend(Put[:result, value]) }
      .map { :finished }
  end

  let(:missing_program) do
    described_class
      .suspend(Get[:missing])
      .bind { |value| described_class.suspend(Put[:result, value]) }
  end

  def interpret_memory(target, memory)
    lambda { |operation|
      case operation
      in Get(key)
        if target == Dry::Monads::Task
          target.new { memory.fetch(key) }
        elsif memory.key?(key)
          Success(memory.fetch(key))
        else
          Failure([:not_found, key])
        end
      in Put(key, value)
        if target == Dry::Monads::Task
          target.new { memory[key] = value }
        else
          Success(memory[key] = value)
        end
      end
    }
  end

  def interpret_log(target, logs)
    lambda { |operation|
      case operation
      in Get(key)
        logs << "get #{key.inspect}"
        target.pure(nil)
      in Put(key, value)
        logs << "put #{key.inspect}=#{value.inspect}"
        target.pure(value)
      end
    }
  end

  describe "construction" do
    it "does not execute continuations or interpreter effects" do
      executed = 0

      described_class
        .suspend(Get[:initial])
        .bind { |value| executed += 1; described_class.suspend(Put[:result, value]) }

      expect(executed).to be(0)
      expect(memory).to eql(initial: 41)
      expect(logs).to be_empty
    end

    it "builds long left-associated bind chains without consuming the call stack" do
      long_program = 10_000.times.inject(described_class.pure(0)) do |current, index|
        current.bind { |value| described_class.suspend([:increment, index]).map { value + 1 } }
      end

      result = long_program.fold_map(Dry::Monads::Result) do
        Success(1)
      end

      expect(result).to eql(Success(10_000))
    end

    it "interprets long chains with Task without nesting callbacks" do
      long_program = 10_000.times.inject(described_class.pure(0)) do |current, _|
        current.bind { |value| described_class.suspend(:increment).map { value + 1 } }
      end

      result = long_program.fold_map(Dry::Monads::Task) do
        Dry::Monads::Task.new { 1 }
      end.to_result

      expect(result).to eql(Success(10_000))
    end
  end

  describe ".pure" do
    it "interprets a pure value in the target monad" do
      expect(described_class.pure(1).fold_map(Dry::Monads::Result) { Failure(:unreachable) }).to eql(Success(1))
      expect(described_class.pure(1).fold_map(Dry::Monads::Task) { Dry::Monads::Task.failed(StandardError.new(:unreachable)) }.wait)
        .to be == Dry::Monads::Task.pure(1).wait
    end
  end

  describe "mixin constructor" do
    it "builds a suspended program" do
      program = Free(:increment)

      expect(program).to be_a(described_class::Suspend)
      expect(program.instruction).to be(:increment)
    end
  end

  describe "#bind and #map" do
    it "interprets the same program against real memory with Result" do
      result = program.fold_map(Dry::Monads::Result, &interpret_memory(Dry::Monads::Result, memory))

      expect(result).to eql(Success(:finished))
      expect(memory).to eql(initial: 41, result: 41)
    end

    it "reuses the same AST with real and logging Result interpreters" do
      memory_result = program.fold_map(Dry::Monads::Result, &interpret_memory(Dry::Monads::Result, memory))
      log_result = program.fold_map(Dry::Monads::Result, &interpret_log(Dry::Monads::Result, logs))

      expect(memory_result).to eql(Success(:finished))
      expect(log_result).to eql(Success(:finished))
      expect(memory).to eql(initial: 41, result: 41)
      expect(logs).to eql(["get :initial", "put :result=nil"])
    end

    it "interprets the same program as pure logs with Result" do
      result = program.fold_map(Dry::Monads::Result, &interpret_log(Dry::Monads::Result, logs))

      expect(result).to eql(Success(:finished))
      expect(logs).to eql(["get :initial", "put :result=nil"])
      expect(memory).to eql(initial: 41)
    end

    it "interprets the same program against real memory with Task" do
      result = program.fold_map(Dry::Monads::Task, &interpret_memory(Dry::Monads::Task, memory)).to_result

      expect(result).to eql(Success(:finished))
      expect(memory).to eql(initial: 41, result: 41)
    end

    it "interprets the same program as pure logs with Task" do
      result = program.fold_map(Dry::Monads::Task, &interpret_log(Dry::Monads::Task, logs)).to_result

      expect(result).to eql(Success(:finished))
      expect(logs).to eql(["get :initial", "put :result=nil"])
      expect(memory).to eql(initial: 41)
    end
  end

  describe "#fold_map" do
    it "lets Result failures stop later operations" do
      result = missing_program.fold_map(Dry::Monads::Result, &interpret_memory(Dry::Monads::Result, memory))

      expect(result).to eql(Failure([:not_found, :missing]))
      expect(memory).to eql(initial: 41)
    end

    it "keeps executing a successful pure log interpretation with Result" do
      result = missing_program.fold_map(Dry::Monads::Result, &interpret_log(Dry::Monads::Result, logs))

      expect(result).to eql(Success(nil))
      expect(logs).to eql(["get :missing", "put :result=nil"])
    end

    it "lets Task failures stop later operations" do
      result = missing_program.fold_map(Dry::Monads::Task, &interpret_memory(Dry::Monads::Task, memory)).to_result

      expect(result).to be_failure
      expect(result.failure).to be_a(KeyError)
      expect(memory).to eql(initial: 41)
    end

    it "keeps executing a successful pure log interpretation with Task" do
      result = missing_program.fold_map(Dry::Monads::Task, &interpret_log(Dry::Monads::Task, logs)).to_result

      expect(result).to eql(Success(nil))
      expect(logs).to eql(["get :missing", "put :result=nil"])
    end
  end
end
