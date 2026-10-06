# frozen_string_literal: true

module Dry
  module Monads
    # Small optics for focusing inside nested structures without hand-writing
    # fmap chains.
    #
    # An optic knows how to focus a part of a whole. A {Lens} focuses a part
    # that is always there (a hash key), a {Prism} focuses a part that may be
    # absent (the value of a Some, an element of an array). Optics compose with
    # {#>>}, so a focus can reach through a Result, into a hash, then into an
    # array, in one definition.
    #
    # Reading and writing never mutate the whole you pass in: updates build new
    # hashes, arrays, and monads, leaving the input untouched.
    #
    # Absence is expressed with the monads you already use. {#preview} returns
    # a Maybe, so a missing key, an out-of-bounds index, or a non-matching
    # prism all come back as None. A focused nil is treated by the semantics of
    # the constructor in play: previewing it gives None (Some cannot hold nil),
    # and rebuilding through Some.new raises, exactly as Some(nil) would.
    #
    # @example
    #   Dry::Monads.load_extensions(:optics)
    #
    #   name = Optics.success >> Optics.key(:users) >> Optics.index(1) >> Optics.key(:name)
    #
    #   name.preview(Success(users: [{name: "Jane"}, {name: "Jade"}])) # => Some("Jade")
    #   name.over(Success(users: [{name: "Jane"}, {name: "Jade"}]), &:upcase)
    #   # => Success({users: [{name: "Jane"}, {name: "JADE"}]})
    #   name.preview(Failure(:oops)) # => None()
    #
    # @api public
    module Optics
      # A composable focus on a part of a structure.
      #
      # This is the common interface of lenses and prisms and the type of
      # every composition that involves a prism.
      #
      # @api public
      class Optic
        # @api private
        def initialize(matcher, setter)
          @matcher = matcher
          @setter = setter
        end

        # Focuses the part, if the structure matches.
        #
        # @param object [Object] the whole
        # @return [Maybe::Some] the focused part
        # @return [Maybe::None] when the structure does not match
        #
        # @api public
        def preview(object)
          @matcher.call(object)
        end

        # Returns a copy of the whole with the focus replaced.
        #
        # A non-matching structure is returned as it is.
        #
        # @param object [Object] the whole
        # @param value [Object] the new focus
        # @return [Object] the updated whole
        #
        # @api public
        def set(object, value)
          @setter.call(object, value)
        end

        # Maps the focus with the block and returns the updated whole.
        #
        # The block is not called when the structure does not match, and the
        # whole is returned unchanged.
        #
        # @param object [Object] the whole
        # @yieldparam focus [Object] the focused part
        # @yieldreturn [Object] the new focus
        # @return [Object] the updated whole
        #
        # @api public
        def over(object)
          focus = preview(object)
          focus.some? ? set(object, yield(focus.value!)) : object
        end

        # Composes with another optic, focusing it inside this one's focus.
        #
        # The composition is a {Lens} only when both optics are lenses.
        #
        # @param other [Optic]
        # @return [Optic]
        #
        # @api public
        def compose(other)
          if is_a?(Lens) && other.is_a?(Lens)
            Lens.new(
              ->(object) { other.view(view(object)) },
              ->(object, value) { set(object, other.set(view(object), value)) }
            )
          else
            Optic.new(
              ->(object) { preview(object).bind { |inner| other.preview(inner) } },
              ->(object, value) { over(object) { |inner| other.set(inner, value) } }
            )
          end
        end
        alias_method :>>, :compose

        # Composes with another optic, focusing this one inside the other's focus.
        #
        # @param other [Optic]
        # @return [Optic]
        #
        # @api public
        def <<(other)
          other.compose(self)
        end
      end

      # An optic on a part that is always present, like a hash key.
      #
      # @api public
      class Lens < Optic
        # @param getter [#call] extracts the focus from the whole
        # @param setter [#call] takes the whole and a new focus, returns an updated whole
        #
        # @api private
        def initialize(getter, setter)
          @getter = getter
          super(->(object) { Maybe.coerce(getter.call(object)) }, setter)
        end

        # Focuses the part.
        #
        # @param object [Object] the whole
        # @return [Object] the focused part
        #
        # @api public
        def view(object)
          @getter.call(object)
        end
      end

      # An optic on a part that may be absent, like the value of a Some.
      #
      # @api public
      class Prism < Optic
        # @param matcher [#call] takes the whole, returns a Maybe of the focus
        # @param setter [#call] takes the whole and a new focus, returns an updated whole
        #
        # @api private
        def initialize(matcher, setter)
          guarded = lambda { |object, value|
            matcher.call(object).some? ? setter.call(object, value) : object
          }
          super(matcher, guarded)
        end
      end

      class << self
        # Builds a lens from a getter and a setter.
        #
        # @param getter [#call] extracts the focus from the whole
        # @param setter [#call] takes the whole and a new focus, returns an updated whole
        # @return [Lens]
        #
        # @api public
        def lens(getter, setter)
          Lens.new(getter, setter)
        end

        # Builds a lens on a hash key.
        #
        # A missing key, or a whole that does not support key access,
        # previews as None.
        #
        # @param name [Object] the key
        # @return [Lens]
        #
        # @api public
        def key(name)
          Lens.new(
            lambda { |object|
              begin
                object[name]
              rescue NoMethodError, TypeError
                nil
              end
            },
            ->(object, value) { object.merge(name => value) }
          )
        end

        # Builds a prism on an array element.
        #
        # An out-of-bounds index, or a whole that is not an array,
        # does not match and previews as None.
        #
        # @param idx [Integer] the index, negative counts from the end
        # @return [Prism]
        #
        # @api public
        def index(idx)
          Prism.new(
            lambda { |array|
              if array.is_a?(::Array) && idx >= -array.size && idx < array.size
                Maybe.coerce(array[idx])
              else
                Maybe::None.instance
              end
            },
            lambda { |array, value|
              copy = array.dup
              copy[idx] = value
              copy
            }
          )
        end

        # Builds a prism from a matcher and a constructor.
        #
        # The constructor rebuilds the whole from a new focus, so a focused nil
        # is handled by the constructor's own semantics: Some.new raises on nil,
        # Maybe.coerce maps it to None.
        #
        # @param matcher [#call] takes the whole, returns a Maybe of the focus
        # @param constructor [#call] takes a new focus, returns the whole
        # @return [Prism]
        #
        # @api public
        def prism(matcher, constructor)
          Prism.new(matcher, ->(_object, value) { constructor.call(value) })
        end

        # A prism on the value of a Some.
        #
        # Rebuilding uses Some.new, so setting nil raises ArgumentError.
        #
        # @return [Prism]
        #
        # @api public
        def some
          prism(
            ->(maybe) { maybe.is_a?(Maybe::Some) ? maybe : Maybe::None.instance },
            Maybe::Some.method(:new)
          )
        end

        # A prism on the value of a Success.
        #
        # @return [Prism]
        #
        # @api public
        def success
          prism(
            lambda { |result|
              result.success? ? Maybe.coerce(result.value!) : Maybe::None.instance
            },
            Result::Success.method(:new)
          )
        end

        # A prism on the error of a Failure.
        #
        # @return [Prism]
        #
        # @api public
        def failure
          prism(
            lambda { |result|
              result.failure? ? Maybe.coerce(result.failure) : Maybe::None.instance
            },
            Monads.method(:Failure)
          )
        end
      end
    end
  end
end
