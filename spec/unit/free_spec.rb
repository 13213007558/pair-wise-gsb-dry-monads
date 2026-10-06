# frozen_string_literal: true

RSpec.describe(Dry::Monads::Free) do
  include Dry::Monads[:free, :result]

  Read = Data.define(:key)
  Write = Data.define(:key, :value)

  subject(:free_monad) { described_class }
  let(:result_monad) { Dry::Monads::Result }
  let(:task_monad) { Dry::Monads::Task }

  let(:memory_program) do
    free_monad.suspend(Read[:name]).bind do |name|
      free_monad.suspend(Write[:NAME, name.upcase]).map { name.upcase }
    end
  end

  let(:failing_program) do
    free_monad.suspend(Read[:missing]).bind do |name|
      free_monad.suspend(Write[:missing_copy, name])
    end
  end

  def result_interpreter(memory, events)
    lambda do |instruction|
      case instruction
      in Read(key)
        events << [:read, key]
        memory.key?(key) ? Success(memory.fetch(key)) : Failure([:not_found, key])
      in Write(key, value)
        events << [:write, key, value]
        Success(memory[key] = value)
      end
    end
  end

  def log_interpreter(events, reads = {})
    lambda do |instruction|
      case instruction
      in Read(key)
        events << [:read, key]
        Success(reads.fetch(key, nil))
      in Write(key, value)
        events << [:write, key, value]
        Success(value)
      end
    end
  end

  def task_interpreter(memory, events)
    lambda do |instruction|
      case instruction
      in Read(key)
        Dry::Monads::Task() do
          events << [:read, key]
          if memory.key?(key)
            memory.fetch(key)
          else
            raise KeyError, "key not found: #{key}"
          end
        end
      in Write(key, value)
        Dry::Monads::Task() do
          events << [:write, key, value]
          memory[key] = value
        end
      end
    end
  end

  describe ".pure" do
    it "wraps a block without calling it" do
      block = -> { :called }

      expect(free_monad.pure(&block).value).to be(block)
    end

    it "is available as a global constructor" do
      expect(Dry::Monads.Free(:instruction).instruction).to be(:instruction)
    end
  end

  describe ".suspend" do
    it "stores an instruction" do
      instruction = Read[:name]

      expect(free_monad.suspend(instruction).instruction).to be(instruction)
    end
  end

  describe "construction" do
    it "does not execute continuations, maps, or interpreters" do
      events = []
      bind_called = false
      map_called = false

      program =
        free_monad
          .suspend(Read[:name])
          .bind { bind_called = true; free_monad.pure(1) }
          .map { map_called = true; _1 + 1 }

      expect(program).to be_a(described_class)
      expect(events).to be_empty
      expect(bind_called).to be(false)
      expect(map_called).to be(false)
    end

    it "uses the Free constructor as a suspend alias" do
      program = Free(Read[:name])

      expect(program.instruction).to eql(free_monad.suspend(Read[:name]).instruction)
    end
  end

  describe "#map" do
    it "transforms interpreted values" do
      program = free_monad.pure(1).map(&:succ).fmap { _1 * 2 }

      expect(program.fold_map(->(_) { Failure(:unreachable) }, result_monad))
        .to eql(Success(4))
    end
  end

  describe "#bind" do
    it "composes programs" do
      program =
        free_monad.suspend(Read[:name]).bind do |name|
          free_monad.pure(name).map(&:upcase)
        end

      events = []

      expect(program.fold_map(log_interpreter(events, name: "alice"), result_monad))
        .to eql(Success("ALICE"))
    end
  end

  describe "#fold_map with Result" do
    it "interprets the same program against real memory" do
      memory = { name: "alice" }
      events = []

      result = memory_program.fold_map(
        result_interpreter(memory, events),
        result_monad
      )

      expect(result).to eql(Success("ALICE"))
      expect(memory).to eql(name: "alice", NAME: "ALICE")
      expect(events).to eql([
        [:read, :name],
        [:write, :NAME, "ALICE"]
      ])
    end

    it "interprets the same program as a pure log" do
      memory = {}
      events = []

      result = memory_program.fold_map(
        log_interpreter(events, name: "alice"),
        result_monad
      )

      expect(result).to eql(Success("ALICE"))
      expect(memory).to be_empty
      expect(events).to eql([
        [:read, :name],
        [:write, :NAME, "ALICE"]
      ])
    end

    it "stops subsequent operations after Failure" do
      memory = {}
      events = []
      continuation_called = false

      program =
        failing_program.bind do
          continuation_called = true
          free_monad.pure(:unreachable)
        end

      result = program.fold_map(result_interpreter(memory, events), result_monad)

      expect(result).to eql(Failure([:not_found, :missing]))
      expect(memory).to be_empty
      expect(events).to eql([[:read, :missing]])
      expect(continuation_called).to be(false)
    end

    it "handles long left-associated bind chains without consuming the Ruby stack" do
      size = 10_000
      program =
        size.times.reduce(free_monad.pure(0)) do |current, _|
          current.bind { |value| free_monad.pure(value + 1) }
        end

      expect(program.fold_map(->(_) { Failure(:unreachable) }, result_monad))
        .to eql(Success(size))
    end

    it "handles long right-associated bind chains without consuming the Ruby stack" do
      size = 5_000
      program = free_monad.suspend(Read[:start])

      size.times do |index|
        program = program.bind { |value| free_monad.pure(value + index) }
      end

      result = program.fold_map(->(_) { Success(0) }, result_monad)

      expect(result).to eql(Success(size.times.sum))
    end
  end

  describe "#fold_map with Task" do
    it "interprets the same program against real memory" do
      memory = { name: "alice" }
      events = []

      result =
        memory_program
          .fold_map(task_interpreter(memory, events), task_monad)
          .wait(5)
          .to_result

      expect(result).to eql(Success("ALICE"))
      expect(memory).to eql(name: "alice", NAME: "ALICE")
      expect(events).to eql([
        [:read, :name],
        [:write, :NAME, "ALICE"]
      ])
    end

    it "interprets the same program as a pure log" do
      memory = {}
      events = []

      result =
        memory_program
          .fold_map(
            ->(instruction) { Dry::Monads::Task { log_interpreter(events, name: "alice").(instruction).value! } },
            task_monad
          )
          .wait(5)
          .to_result

      expect(result).to eql(Success("ALICE"))
      expect(memory).to be_empty
      expect(events).to eql([
        [:read, :name],
        [:write, :NAME, "ALICE"]
      ])
    end

    it "stops subsequent operations after rejection" do
      memory = {}
      events = []
      continuation_called = false

      program =
        failing_program.bind do
          continuation_called = true
          free_monad.pure(:unreachable)
        end

      result =
        program
          .fold_map(task_interpreter(memory, events), task_monad)
          .wait(5)
          .to_result

      expect(result).to be_a_failure
      expect(result.failure).to be_a(StandardError)
      expect(memory).to be_empty
      expect(events).to eql([[:read, :missing]])
      expect(continuation_called).to be(false)
    end

    it "turns interpreter exceptions into rejected tasks" do
      result =
        free_monad
          .suspend(:boom)
          .fold_map(task_monad) { raise StandardError, "interpreter boom" }
          .wait(5)
          .to_result

      expect(result).to be_a_failure
      expect(result.failure.message).to eql("interpreter boom")
    end

    it "handles long left-associated bind chains without consuming the Ruby stack" do
      size = 3_000
      program =
        size.times.reduce(free_monad.pure(0)) do |current, _|
          current.bind { |value| free_monad.pure(value + 1) }
        end

      result =
        program
          .fold_map(->(_) { task_monad.pure(:unreachable) }, task_monad)
          .wait(10)
          .to_result

      expect(result).to eql(Success(size))
    end

    it "handles long bind chains with immediate tasks" do
      immediate = Concurrent::ImmediateExecutor.new
      size = 3_000
      program = free_monad.suspend(:start)

      size.times do |index|
        program = program.bind do |value|
          free_monad.suspend(:step).map { |step| value + step + index }
        end
      end

      result =
        program
          .fold_map(task_monad) { Dry::Monads::Task[immediate] { 0 } }
          .wait(10)
          .to_result

      expect(result).to eql(Success(size.times.sum))
    end

    it "accepts the interpreter as a block" do
      result =
        free_monad
          .suspend(Read[:name])
          .map(&:upcase)
          .fold_map(task_monad) do |instruction|
            Dry::Monads::Task() { instruction.key.to_s.upcase }
          end
          .wait(5)
          .to_result

      expect(result).to eql(Success("NAME"))
    end
  end

  describe "#fold_map arguments" do
    it "requires a callable interpreter" do
      expect {
        free_monad.pure(1).fold_map(:not_callable, result_monad)
      }.to raise_error(TypeError, "interpreter must be callable, got :not_callable")
    end

    it "requires a supported target monad" do
      expect {
        free_monad.pure(1).fold_map(->(_) { nil }, Dry::Monads::Maybe)
      }.to raise_error(ArgumentError, "target must be Result or Task")
    end
  end
end
