# frozen_string_literal: true

RSpec.describe "optics extension" do
  include Dry::Monads[:maybe, :result]

  before(:all) do
    Dry::Monads.load_extensions(:optics)
  end

  let(:lens) { Dry::Monads::Extensions::Optics::Lens }
  let(:prism) { Dry::Monads::Extensions::Optics::Prism }
  let(:optional) { Dry::Monads::Extensions::Optics::Optional }

  describe "Lens" do
    it "views, sets and maps a hash key" do
      key = lens.key(:name)

      expect(key.view({name: "jane"})).to eql("jane")
      expect(key.set({name: "jane"}, "joe")).to eql({name: "joe"})
      expect(key.over({name: "jane"}, &:capitalize)).to eql({name: "Jane"})
    end

    it "does not mutate the input hash" do
      input = {name: "jane"}.freeze

      expect(lens.key(:name).set(input, "joe")).to eql({name: "joe"})
      expect(input).to eql({name: "jane"})
    end

    it "maps an array index without mutating the input" do
      input = %w[a b].freeze
      index = lens.index(1)

      expect(index.view(input)).to eql("b")
      expect(index.over(input, &:upcase)).to eql(%w[a B])
      expect(input).to eql(%w[a b])
    end

    it "maps an attribute of a business object without mutating it" do
      user_class = Struct.new(:name, :email)
      user = user_class.new("jane", "jane@example.com")

      updated = lens.attr(:name).over(user, &:capitalize)

      expect(updated.name).to eql("Jane")
      expect(updated.email).to eql("jane@example.com")
      expect(user.name).to eql("jane")
    end

    it "previews nil focuses as None" do
      expect(lens.key(:missing).preview({})).to be_none
      expect(lens.key(:name).preview({name: "jane"})).to eql(Some("jane"))
    end
  end

  describe "lens laws" do
    let(:optic) { lens.key(:user) >> lens.key(:name) }
    let(:structure) { {user: {name: "jane", age: 30}, id: 1} }

    it "view-after-set returns the set value (get-set)" do
      expect(optic.view(optic.set(structure, "joe"))).to eql("joe")
    end

    it "setting the viewed value is a no-op (set-get)" do
      expect(optic.set(structure, optic.view(structure))).to eql(structure)
    end

    it "the last set wins (set-set)" do
      expect(optic.set(optic.set(structure, "joe"), "jane")).to eql(optic.set(structure, "jane"))
    end
  end

  describe "composition order" do
    let(:user_name) { lens.key(:user) >> lens.key(:name) }
    let(:name_user) { lens.key(:name) >> lens.key(:user) }
    let(:structure) { {user: {name: "jane"}} }

    it "composes outside-in" do
      expect(user_name.view(structure)).to eql("jane")
    end

    it "is not commutative" do
      expect(name_user.preview(structure)).to be_none
    end

    it "sets through the whole path, preserving siblings" do
      input = {user: {name: "jane", age: 30}, id: 1}

      expect(user_name.set(input, "joe")).to eql({user: {name: "joe", age: 30}, id: 1})
    end

    it "keeps Lens + Lens a Lens" do
      expect(user_name).to be_a(lens)
      expect(user_name).to respond_to(:view)
    end

    it "turns Lens + Prism into an Optional without #view" do
      optic = lens.key(:result) >> prism.success

      expect(optic).to be_a(optional)
      expect(optic).not_to respond_to(:view)
      expect(optic.preview({result: Success(1)})).to eql(Some(1))
      expect(optic.preview({result: Failure(:e)})).to be_none
    end

    it "turns Prism + Lens into an Optional" do
      optic = prism.success >> lens.key(:name)

      expect(optic).to be_a(optional)
      expect(optic.over(Success({name: "jane"}), &:capitalize)).to eql(Success({name: "Jane"}))
    end
  end

  describe "Prism" do
    it "previews matching and non-matching structures" do
      expect(prism.some.preview(Some(1))).to eql(Some(1))
      expect(prism.some.preview(None())).to be_none
      expect(prism.success.preview(Success(1))).to eql(Some(1))
      expect(prism.success.preview(Failure(:e))).to be_none
      expect(prism.failure.preview(Failure(:e))).to eql(Some(:e))
    end

    it "does not call the update function on a mismatch" do
      none = Dry::Monads::Maybe::None.instance
      called = false

      expect(prism.some.over(none) { called = true }).to be(none)
      expect(called).to be(false)
    end

    it "returns the very same object on a mismatched set" do
      failure = Failure(:e)

      expect(prism.success.set(failure, 1)).to be(failure)
      expect(prism.success.over(failure, &:succ)).to be(failure)
    end

    it "satisfies review-preview" do
      expect(prism.success.preview(prism.success.review(1))).to eql(Some(1))
      expect(prism.some.preview(prism.some.review(1))).to eql(Some(1))
    end

    it "satisfies preview-set identity on matching structures" do
      success = Success(1)

      expect(prism.success.set(success, prism.success.preview(success).value!)).to eql(success)
    end

    it "handles nil with the semantics of the chosen constructor" do
      expect(prism.success.review(nil)).to eql(Success(nil))
      expect { prism.some.review(nil) }.to raise_error(ArgumentError, /nil cannot be some/)
    end

    it "handles nil update results with the semantics of the chosen constructor" do
      expect(prism.success.over(Success(1)) { nil }).to eql(Success(nil))
      expect { prism.some.over(Some(1)) { nil } }.to raise_error(ArgumentError, /nil cannot be some/)
    end
  end

  describe "prism composition" do
    let(:optic) { prism.success >> prism.some }

    it "stays a Prism" do
      expect(optic).to be_a(prism)
    end

    it "previews through both cases" do
      expect(optic.preview(Success(Some(1)))).to eql(Some(1))
      expect(optic.preview(Success(None()))).to be_none
      expect(optic.preview(Failure(:e))).to be_none
    end

    it "reviews inside-out" do
      expect(optic.review(1)).to eql(Success(Some(1)))
    end
  end

  describe "Result with a nested array" do
    let(:optic) do
      prism.success >> lens.key(:items) >> lens.index(1) >> lens.key(:name)
    end

    let(:result) { Success({items: [{name: "a"}, {name: "b"}]}) }

    it "previews the deeply nested focus" do
      expect(optic.preview(result)).to eql(Some("b"))
    end

    it "maps the deeply nested focus" do
      expect(optic.over(result, &:upcase)).to eql(Success({items: [{name: "a"}, {name: "B"}]}))
    end

    it "sets the deeply nested focus" do
      expect(optic.set(result, "z")).to eql(Success({items: [{name: "a"}, {name: "z"}]}))
    end

    it "does not mutate the input" do
      input = Success({items: [{name: "a"}.freeze, {name: "b"}.freeze].freeze}.freeze)

      optic.over(input, &:upcase)

      expect(input).to eql(Success({items: [{name: "a"}, {name: "b"}]}))
    end

    it "returns None when an array element is missing" do
      expect(optic.preview(Success({items: [{name: "a"}]}))).to be_none
    end

    it "leaves Failure untouched without calling the update function" do
      failure = Failure(:not_found)
      called = false

      expect(optic.over(failure) { called = true }).to be(failure)
      expect(called).to be(false)
    end
  end
end
