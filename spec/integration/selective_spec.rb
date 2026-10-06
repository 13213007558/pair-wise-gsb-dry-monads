# frozen_string_literal: true

require "tmpdir"
require "pathname"
require "yaml"

RSpec.describe("selective tasks") do
  include Dry::Monads::Result::Mixin
  include Dry::Monads::Lazy::Mixin

  it "reads local config and runs the fallback query only when config is absent" do
    Dir.mktmpdir do |dir|
      primary = Pathname(File.join(dir, "config.yml"))
      fallback = Pathname(File.join(dir, "fallback.yml"))
      fallback.write("endpoint: local-fallback\n")

      fallback_runs = 0

      read_config = lambda do |path|
        Lazy do
          if path.exist?
            Success(YAML.safe_load(path.read))
          else
            Failure(:config_missing)
          end
        end
      end

      fallback_query = Lazy do
        ->(_missing) {
          fallback_runs += 1
          YAML.safe_load(fallback.read)
        }
      end

      primary.write("endpoint: local-primary\n")
      configured = read_config.call(primary).select(fallback_query)

      expect(configured.branch_count).to be(1)
      expect(configured.possible_operations.size).to be(2)
      expect(configured.value!).to eql("endpoint" => "local-primary")
      expect(fallback_runs).to be(0)

      missing = Pathname(File.join(dir, "missing.yml"))
      selected = read_config.call(missing).select(fallback_query)

      expect(selected.value!).to eql("endpoint" => "local-fallback")
      expect(fallback_runs).to be(1)
    end
  end
end
