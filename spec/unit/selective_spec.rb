# frozen_string_literal: true

require "json"
require "tempfile"

RSpec.describe(Dry::Monads::Selective) do
  include Dry::Monads[:result]

  describe "Result selective laws" do
    it "satisfies the identity law" do
      identity = Success(-> value { value })

      [Success(Success(:right)), Success(Failure(:left)), Failure(:outer)].each do |selector|
        selected = selector.select(identity)
        expected = selector.fmap do |either|
          either.success? ? either.success : either.failure
        end

        expect(selected).to eql(expected)
      end
    end

    it "does not run the alternative when the value is already present" do
      called = false

      selected = Success(Success(1)).select(
        Success(-> _ { called = true })
      )

      expect(selected).to eql(Success(1))
      expect(called).to be(false)
    end

    it "applies the alternative to a missing value" do
      selected = Success(Failure(2)).select(Success(-> value { value * 3 }))

      expect(selected).to eql(Success(6))
    end

    it "preserves an outer failure and propagates an alternative failure" do
      alternative = Success(-> value { value * 3 })

      expect(Failure(:outer).select(alternative)).to eql(Failure(:outer))
      expect(Success(Failure(2)).select(Failure(:missing))).to eql(Failure(:missing))
    end
  end

  describe ".branch with Result" do
    it "selects the matching branch" do
      expect(described_class.branch(Success(true), Success(:yes), Success(:no)))
        .to eql(Success(:yes))
      expect(described_class.branch(Success(false), Success(:yes), Success(:no)))
        .to eql(Success(:no))
      expect(described_class.branch(Failure(:outer), Success(:yes), Success(:no)))
        .to eql(Failure(:outer))
    end
  end

  describe "started and deferred tasks" do
    it "starts Task.operation immediately and keeps Lazy.operation deferred" do
      started = Dry::Monads::Task.operation(:started) { sleep(0.01); 1 }
      deferred = Dry::Monads::Lazy.operation(:deferred) { 1 }

      expect(started).to be_started
      expect(deferred).not_to be_started
      expect(deferred).to be_deferred
    end

    it "does not start a deferred alternative for an available task value" do
      alternative = Dry::Monads::Lazy.operation(:query) { ->(_) { raise "should not run" } }
      program = Dry::Monads::Task.pure(Success(:ready)).select(alternative)

      expect(program.wait.value!).to be(:ready)
      expect(alternative).to be_deferred
    end

    it "starts a deferred alternative only for a missing task value" do
      alternative = Dry::Monads::Lazy.operation(:query) { ->(_) { :found } }
      program = Dry::Monads::Task.pure(Failure(:missing)).select(alternative)

      expect(program.wait.value!).to be(:found)
      expect(alternative).to be_started
      expect(alternative).not_to be_deferred
    end
  end

  describe "branch counting with Lazy" do
    it "lists potential operations before execution and counts one branch" do
      primary_called = false
      backup_called = false

      primary = Dry::Monads::Lazy.operation(:primary) { primary_called = true; :primary }
      backup = Dry::Monads::Lazy.operation(:backup) { backup_called = true; :backup }
      program = described_class.branch(Dry::Monads::Lazy.new { true }, primary, backup)

      expect(program).to be_deferred
      expect(program.branch_count).to be(1)
      expect(program.possible_operations).to eq(%i[primary backup])

      expect(program.value!).to be(:primary)
      expect(primary_called).to be(true)
      expect(backup_called).to be(false)
      expect(backup).to be_deferred
    end

    it "starts only the selected branch when the condition is false" do
      primary_called = false
      backup_called = false

      primary = Dry::Monads::Lazy.operation(:primary) { primary_called = true; :primary }
      backup = Dry::Monads::Lazy.operation(:backup) { backup_called = true; :backup }
      program = described_class.branch(Dry::Monads::Lazy.new { false }, primary, backup)

      expect(program.value!).to be(:backup)
      expect(primary_called).to be(false)
      expect(backup_called).to be(true)
      expect(primary).to be_deferred
    end
  end

  describe "local configuration example" do
    def config_program(path, backup_queries)
      reads = 0
      config = Dry::Monads::Lazy.operation(:read_config) do
        reads += 1
        data = JSON.parse(File.read(path))
        if data.key?("token")
          Success(data.fetch("token"))
        else
          Failure(:missing_token)
        end
      end

      backup = Dry::Monads::Lazy.operation(:backup_query) do
        ->(_) { backup_queries.call }
      end

      [config.select(backup), -> { reads }]
    end

    it "uses a local config token and never runs the backup query" do
      Tempfile.create(["config", ".json"]) do |file|
        file.write(JSON.generate(token: "config-token"))
        file.flush

        queries = 0
        program, = config_program(file.path, -> { queries += 1; "backup-token" })

        expect(program).to be_deferred
        expect(program.branch_count).to be(1)
        expect(program.possible_operations).to eq(%i[read_config backup_query])
        expect(program.value!).to eql("config-token")
        expect(program.value!).to eql("config-token")
        expect(queries).to be(0)
      end
    end

    it "runs the local backup query when config has no token" do
      Tempfile.create(["config", ".json"]) do |file|
        file.write(JSON.generate({}))
        file.flush

        queries = 0
        program, reads = config_program(file.path, -> { queries += 1; "backup-token" })

        expect(program.value!).to eql("backup-token")
        expect(queries).to be(1)
        expect(reads.call).to be(1)
      end
    end
  end
end
