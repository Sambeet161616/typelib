require 'enumerator'
require 'utilrb/object/singleton_class'
require 'delegate'
require 'pp'

# Typelib is the main module for Ruby-side Typelib functionality.
#
# Typelib allows to do two things:
#
# * represent types (it is a <i>type system</i>). These representations will be
#   referred to as _types_ in the documentation.
# * manipulate in-memory values represented by these types. These are
#   referred to as _values_ in the documentation.
#
# As types may depend on each other (for instance, a structure depend on the
# types used to define its fields), Typelib maintains a consistent set of types
# in a so-called registry. Types in a registry can only refer to other types in
# the same registry.
#
# On the Ruby side, a _type_ is represented as a subclass of one of the
# specialized subclasses of Typelib::Type (depending of what kind of type it
# is). I.e.  a _type_ itself is a class, and the methods that are available on
# Type objects are the singleton methods of the Type class (or its specialized
# subclasses).  Then, a value is simply an instance of that same class.
#
# Typelib specializes for the following kinds of types:
#
# * structures and unions (Typelib::CompoundType)
# * static length arrays (Typelib::ArrayType)
# * dynamic containers (Typelib::ContainerType)
# * mappings from strings to numerical values (Typelib::EnumType)
#
# In other words:
#
#   registry = <load the registry>
#   type  = registry.get 'A' # Get the Type subclass that represents the A
#                            # structure
#   value = type.new         # Create an uninitialized value of type A
#
#   value.class == type # => true
#   type.ancestors # => [type, Typelib::CompoundType, Typelib::Type]
#
# Each class representing a type can be further specialized using
# Typelib.specialize_model and Typelib.specialize
# 
module Typelib
    class << self
        # A type name to module mapping of the specializations defined by
        # Typelib.specialize
        attr_reader :value_specializations
        # A type name to module mapping of the specializations defined by
        # Typelib.specialize_model
        attr_reader :type_specializations
        # A [ruby class, type name] to block mapping of the custom convertions
        # defined by Typelib.convert_from_ruby
        attr_reader :convertions
    end

    @value_specializations = Hash.new
    @type_specializations = Hash.new
    @convertions    = Hash.new

    # Adds methods to the type objects.
    #
    # The objects returned by registry.get(type_name) are themselves classes.
    # This method allows to define singleton methods, i.e. methods that will be
    # available on the type objects returned by Registry#get
    #
    # It can be for instance used to convert a typelib value into the
    # corresponding Ruby type (if there is one).
    #
    # For instance, given a hypothetical timeval type that would be defined (in
    # C) by
    #
    #   struct timeval
    #   {
    #       int32_t seconds;
    #       uint32_t microseconds;
    #   };
    #
    # one could make sure that timeval values get automatically converted to
    # Ruby's Time with
    #
    #   Typelib.specialize_model '/timeval' do
    #     def to_ruby(value)
    #       Time.at(value.seconds, value.microseconds)
    #     end
    #   end
    #
    # See Typelib.specialize to add instance methods to the values of a given
    # Typelib type
    def self.specialize_model(name, &block)
        type_specializations[name] ||= Array.new
        type_specializations[name] << Module.new(&block)
    end

    # Extends instances of a given Typelib type
    #
    # This method allows to add methods that are then available on Typelib
    # values.
    #
    # For instance, if we assume that a Vector3 type is defined by
    #
    #   struct Vector3
    #   {
    #     double data[3];
    #   };
    #
    # Then
    #
    #   Typelib.specialize '/Vector3' do
    #     def +(other_v)
    #       result = new
    #       3.times do |i|
    #         result.data[i] = data[i] + other_v.data[i]
    #       end
    #     end
    #   end
    #
    # will make it possible to add two values of the Vector3 type in Ruby
    def self.specialize(name, &block)
        value_specializations[name] ||= Array.new
        value_specializations[name] << Module.new(&block)
    end

    # Define specialized convertions from Ruby objects to Typelib-managed
    # values.
    #
    # For instance, to allow the usage of Time instances to initialize structure
    # fields of the timeval type presented in Typelib.specialize_model, one
    # would do
    #
    #   Typelib.convert_from_ruby Time, '/timeval' do |value, typelib_type|
    #     v = typelib_type.new
    #     v.seconds      = value.tv_sec
    #     v.microseconds = value.tv_usec
    #   end
    #
    # It will then be possible to do
    #
    #   a.time = Time.now
    #
    # where 'a' is a value of a structure that has a 'time' field of the timeval
    # type, as for instance
    #
    #   struct A
    #   {
    #     timeval time;
    #   };
    #
    def self.convert_from_ruby(ruby_class, typename, &block)
        convertions[[ruby_class, typename]] = lambda(&block)
    end 

    # The namespace separator character used by Typelib
    NAMESPACE_SEPARATOR = '/'

    # Base class for all types
    # Registry types are wrapped into subclasses of Type
    # or other Type-derived classes (Array, Pointer, ...)
    #
    # Value objects are wrapped into instances of these classes
    class Type
        # Creates an instance of Type (or one of its subclasses) that represents
        # +arg+.
        #
        # If +arg+ is already a Typelib value of the right type, it will be
        # returned. In other words, it is not guaranteed that the return value
        # is different from +arg+ itself.
        def self.from_ruby(arg)
            filtered = Typelib.filter_argument(arg, self)
            if filtered.kind_of?(Typelib::Type)
                filtered
            else
                result = new
                result.initialize_from_ruby(filtered)
                result
            end
        end

        # Called by Typelib when a subclass is created.
        def self.subclass_initialize
            if mods = Typelib.type_specializations[name]
                mods.each { |m| extend m }
            end
            if mods = Typelib.value_specializations[name]
                mods.each { |m| include m }
            end
            super if defined? super
        end

        # Returns a new Type instance that contains the same value, but using a
        # different type object
        #
        # It raises ArgumentError if the cast is invalid.
        #
        # The ability to cast can be checked beforehand by using Type.casts_to?
        #
        # Note that the return value might be +self+, and that both objects
        # refer to the same memory zone. Therefore, if one of the two value
        # objects is used to modify the underlying value, that will be reflected
        # in the other. Moreover, both values should not be modified in two
        # different threads without proper locking.
        def cast(target_type)
            if !self.class.casts_to?(target_type)
                raise ArgumentError, "cannot cast #{self} to #{target_type}"
            end
            do_cast(target_type)
        end

        # Creates a deep copy of this value.
        #
        # It is guaranteed that this value will be referring to a different
        # memory zone than +self+
	def dup
	    new = self.class.new
	    Typelib.copy(new, self)
	end
        alias clone dup

        class << self
	    # The Typelib::Registry this type belongs to
            attr_reader :registry

	    # The type's full name (i.e. name and namespace). In typelib,
	    # namespace components are separated by '/'
	    def name
		if defined? @name
		    @name
		else
		    super
		end
	    end

	    # Returns the namespace part of the type's name.  If +separator+ is
	    # given, the namespace components are separated by it, otherwise,
	    # the default of Typelib::NAMESPACE_SEPARATOR is used. If nil is
	    # used as new separator, no change is made either.
	    def namespace(separator = Typelib::NAMESPACE_SEPARATOR, remove_leading = false)
		ns = do_namespace
		if remove_leading
		    ns = ns[1..-1]
		end
		if separator && separator != Typelib::NAMESPACE_SEPARATOR
		    ns.gsub!(Typelib::NAMESPACE_SEPARATOR, separator)
		end
		ns
	    end

            # Returns the basename part of the type's name, i.e. the type name
            # without the namespace part.
            def basename(separator = Typelib::NAMESPACE_SEPARATOR)
                name = do_basename
		if separator && separator != Typelib::NAMESPACE_SEPARATOR
		    name.gsub!(Typelib::NAMESPACE_SEPARATOR, separator)
		end
		name
            end

            # Returns the complete name for the type (both namespace and
            # basename). If +separator+ is set to a value different than
            # Typelib::NAMESPACE_SEPARATOR, Typelib's namespace separator will
            # be replaced by the one given in argument.
            #
            # For instance,
            #
            #   type_t.full_name('::')
            #
            # will return the C++ name for the given type
	    def full_name(separator = Typelib::NAMESPACE_SEPARATOR, remove_leading = false)
		result = namespace(separator, remove_leading) + basename(separator)
	    end

	    def to_s; "#<#{superclass.name}: #{name}>" end

	    # are we a null type ?
	    def null?; @null end
            # True if this type is opaque
            #
            # Values from opaque types cannot be manipulated by Typelib. They
            # are usually used to refer to fields that will be converted first
            # (by some unspecified means) to a value that Typelib can manipulate
            def opaque?; @opaque end

	    # Returns the pointer-to-self type
            def to_ptr; registry.build(name + "*") end

            def pretty_print(pp) # :nodoc:
		pp.text name 
	    end

            alias :__real_new__ :new

            # Creates a new value from either a MemoryZone instance (i.e. a
            # pointer), or from a marshalled version of a value.
            #
            # This is usually used to reload a value marshalled with
            # to_byte_array
            #
            # For instance,
            #
            #   type = registry.get 'A'
            #   value = type.new
            #   # modify +value+
            #   marshalled = value.to_byte_array
            #   # save +marshalled+ to a file (for instance)
            #
            # Later on ...
            #
            #   # load +marshalled+ from the file
            #   type = registry.get 'A'
            #   value = type.wrap(marshalled)
            #
            def wrap(ptr)
		if null?
		    raise TypeError, "this is a null type"
                elsif !(ptr.kind_of?(String) || ptr.kind_of?(MemoryZone))
                    raise ArgumentError, "can only wrap strings and memory zones"
		end
	       	__real_new__(ptr) 
	    end

            # Creates a new value of the given type.
            #
            # Note that the value is *not* initialized. To initialize a value to
            # zero, one can call Type#zero!
            def new; __real_new__(nil) end

	    # Check if this type is a +typename+. If +typename+
	    # is a string or a regexp, we match it against the type
	    # name. Otherwise we call Class#<
	    def is_a?(typename)
		if typename.respond_to?(:to_str)
		    typename.to_str === self.name
		elsif Regexp === typename
		    typename === self.name
		else
		    self <= typename
		end
	    end
        end

	# Module that gets mixed into types which can
	# be converted to strings (char* for instance)
	module StringHandler
	    def to_str
		Type::to_string(self)
	    end
	    def from_str(value)
		Type::from_string(self, value)
	    end
	end

	def initialize(*args)
	    __initialize__(*args)
	    extend StringHandler if string_handler?
	end

	# Check for value equality
        def ==(other)
	    # If other is also a type object, we first
	    # check basic constraints before trying conversion
	    # to Ruby objects
            if Type === other
		return Typelib.compare(self, other)
	    else
		if (ruby_value = self.to_ruby).eql?(self)
		    return false
		end
		other == self.to_ruby
	    end
        end

	# Returns a PointerType object which points to +self+. Note that
	# to_ptr.deference == self
        def to_ptr
            pointer = self.class.to_ptr.wrap(@ptr.to_ptr)
	    pointer.instance_variable_set(:@points_to, self)
	    pointer
        end
	
	alias :__to_s__ :to_s
	def to_s # :nodoc:
	    if respond_to?(:to_str)
		to_str
	    elsif ! (ruby_value = to_ruby).eql?(self)
		ruby_value.to_s
	    else
		__to_s__
	    end
	end

	def pretty_print(pp) # :nodoc:
	    pp.text to_s
	end

        # Get the memory pointer for self
        def to_memory_ptr; @ptr end

	def is_a?(typename); self.class.is_a?(typename) end

        def inspect
            sprintf("#<%s:%s @%s>", self.class.superclass.name, self.class.name, to_memory_ptr.inspect)
        end
    end

    # Base class for compound types (structs, unions)
    #
    # See the Typelib module documentation for an overview about how types are
    # values are represented.
    class CompoundType < Type
	# Initializes this object to the pointer +ptr+, and initializes it
	# to +init+. Valid values for +init+ are:
	# * a hash, in which case it is a { field_name => field_value } hash
	# * an array, in which case the fields are initialized in order
	# Note that a compound should be either fully initialized or not initialized
        def initialize(ptr, *init)
	    # A hash in which we cache Type objects for each of the structure fields
	    @fields = Hash.new

            super(ptr)
            return if init.empty?

            init = init.first if init.size == 1 && Hash === init.first

	    fields = self.class.fields
	    
            # init is either an array of values (the fields in order) or a hash
            # (named parameters)
            if Hash === init
                # init.each shall yield (name, value)
                init.each do |name, value| 
		    name = name.to_s
		    self[name] = value 
		end
            else
                # we assume that the values are given in order
                init.each_with_index do |value, idx| 
		    self[self.class.fields[idx].first] = value
		end
            end
        end

        # Initializes a new structure value from +arg+
        #
        # +arg+ can either be a value of this type, or a hash. In the latter
        # case, each fields of the new value will be initialized one by one
        # using the hash values.
        def self.from_ruby(arg)
            if arg.kind_of?(Hash) then new(arg)
            else
                raise ArgumentError, "cannot initialize a value of type #{self} from #{arg.inspect}"
            end
        end

        class << self
            def new(*init) # :nodoc:
                __real_new__(nil, *init)
            end

            def wrap(ptr, *init) # :nodoc:
                if !(ptr.kind_of?(String) || ptr.kind_of?(MemoryZone))
                    raise ArgumentError, "can only wrap strings and memory zones"
                end

                __real_new__(ptr, *init)
            end

	    # Check if this type can be used in place of +typename+
	    # In case of compound types, we check that either self, or
	    # the first element field is +typename+
	    def is_a?(typename)
		super || self.fields[0].last.is_a?(typename)
	    end

	    # Called by the extension to initialize the subclass
	    # For each field, it creates getters and setters on 
	    # the object, and a getter in the singleton class 
	    # which returns the field type
            def subclass_initialize
                @fields = get_fields.map! do |name, offset, type|
                    if !method_defined?(name)
			define_method(name) { self[name] }
                        define_method("#{name}=") { |value| self[name] = value }
                    end
                    if !singleton_class.method_defined?(name)
                        singleton_class.send(:define_method, name) { || type }
                    end

                    [name, type]
                end

                super if defined? super
            end

            # Returns the offset, in bytes, of the given field
            def offset_of(fieldname)
                get_fields.each do |name, offset, _|
                    return offset if name == fieldname
                end
                raise "no such field #{fieldname} in #{self}"
            end

	    # The list of fields
            attr_reader :fields
	    # Returns the type of +name+
            def [](name); @fields.find { |n, t| n == name }.last end
            # True if the given field is defined
            def has_field?(name); @fields.any? { |n, t| n == name } end
	    # Iterates on all fields
            def each_field # :yield:name, type
		@fields.each { |field| yield(*field) } 
	    end

	    def pretty_print_common(pp) # :nodoc:
                pp.group(2, '{', '}') do
		    pp.breakable
                    all_fields = get_fields.to_a
                    
                    pp.seplist(all_fields) do |field|
			yield(*field)
                    end
                end
	    end

            def pretty_print(pp) # :nodoc:
		super
		pp.text ' '
		pretty_print_common(pp) do |name, offset, type|
		    pp.text name
		    pp.text "[#{offset}] <"
		    pp.nest(2) do
                        type.pretty_print(pp)
		    end
		    pp.text '>'
		end
            end
        end

	def pretty_print(pp) # :nodoc:
	    self.class.pretty_print_common(pp) do |name, offset, type|
		pp.text name
		pp.text "="
		self[name].pretty_print(pp)
	    end
	end

        # Sets the value of the field +name+. If +value+ is a hash, we expect
        # that the field is a compound type and initialize it using the keys of
        # +value+ as field names
        def []=(name, value)
            name = name.to_s
            attribute = get_field(name)
	    if Hash === value
		return value.each { |k, v| attribute[k] = v }
            end

            if attribute.kind_of?(Typelib::Type) && value.kind_of?(Typelib::Type)
                return Typelib.copy(attribute, value)
            end

            # Now, try other methods. Either delegate to the subclass if the
            # subclass wants it, or convert the type from Ruby and copy
            if attribute.respond_to?(:set_values)
                attribute.set_values(value)
	    else
                value = Typelib.from_ruby(value, self.class[name])

                # If +value+ is already a typelib value, try to copy the attribute
                if attribute.kind_of?(Typelib::Type) && value.kind_of?(Typelib::Type)
                    return Typelib.copy(attribute, value)
                end
		set_field(name, value)
	    end

	rescue ArgumentError => e
	    if e.message =~ /^no field \w+ in /
		raise e, (e.message + " in #{name}(#{self.class.name})"), e.backtrace
	    else
		raise e, (e.message + " while setting #{name} in #{self.class.name}"), e.backtrace
	    end
	rescue TypeError => e
	    raise e, "#{e.message} for #{self.class.name}.#{name}", e.backtrace
	end

	# Returns the value of the field +name+
        def [](name)
	    if !(value = @fields[name])
		value = get_field(name)
		if value.kind_of?(Type)
		    @fields[name] = value
		end
	    end
            field_type = self.class[name]
            if field_type.respond_to?(:to_ruby)
                field_type.to_ruby(value)
            else
                value
            end
	end

        def to_ruby # :nodoc:
           self
        end
    end

    class IndirectType < Type
    end

    # Base class for static-length arrays
    #
    # See the Typelib module documentation for an overview about how types are
    # values are represented.
    class ArrayType < IndirectType
	def pretty_print(pp) # :nodoc:
	    all_fields = enum_for(:each_with_index).to_a

	    pp.text '['
	    pp.nest(2) do
		pp.breakable
		pp.seplist(all_fields) do |element|
		    element, index = *element 
		    pp.text "[#{index}] = "
		    element.pretty_print(pp)
		end
	    end
	    pp.breakable
	    pp.text ']'
	end

        # Used by CompoundType#[] to initialize an array from a Ruby enumerable
        def set_values(enumerable) # :nodoc:
            enumerable.each_with_index do |value, i|
                self[i] = value
            end
        end

	# Returns the pointed-to type (defined for consistency reasons)
	def self.[](index); deference end

        def to_ruby # :nodoc:
	    if respond_to?(:to_str); to_str
	    else self 
	    end
	end

        include Enumerable
    end

    # Base class for pointer types
    #
    # When returned as fields of a structure, or as return values from a
    # function, pointers might be converted in the following cases:
    # * nil if it is NULL
    # * a String object if it is a pointer to char
    #
    # See the Typelib module documentation for an overview about how types are
    # values are represented.
    class PointerType < IndirectType
        # Creates and initializes to zero a value of this pointer type
        def self.create_null
            result = new
            result.zero!
            result
        end

	# Converts the pointer to its Ruby equivalent.
        #
        # Pointers get converted in the following cases:
        # * nil if it is NULL
        # * a String object if it is a pointer to char
        def to_ruby
	    if self.null?; nil
	    elsif respond_to?(:to_str); to_str
	    else self
	    end
       	end
    end

    # Base class for all dynamic containers
    #
    # See the Typelib module documentation for an overview about how types are
    # values are represented.
    class ContainerType < IndirectType
        include Enumerable

        # True if this container is empty
        def empty?; length == 0 end

        # Appends a new element to this container
        def <<(value); insert(Typelib.from_ruby(value)) end

        # Used by CompoundType#[] to initialize an array from a Ruby enumerable
        def set_values(enumerable) # :nodoc:
            clear
            enumerable.each do |value|
                insert(value)
            end
        end

        def pretty_print(pp)
            index = 0
	    pp.text '['
	    pp.nest(2) do
		pp.breakable
		pp.seplist(enum_for(:each)) do |element|
		    pp.text "[#{index}] = "
		    element.pretty_print(pp)
                    index += 1
		end
	    end
	    pp.breakable
	    pp.text ']'
        end

        def to_ruby
            self
        end
    end

    # Base class for all enumeration types. Enumerations
    # are mappings from strings to integers
    #
    # See the Typelib module documentation for an overview about how types are
    # values are represented.
    class EnumType < Type
        def self.from_ruby(value)
            result = new
            result.initialize_from_ruby(value)
            result
        end

        class << self
	    # A value => key hash for each enumeration values
            attr_reader :values

            def pretty_print(pp) # :nodoc:
                super
		pp.text '{'
                pp.nest(2) do
		    pp.breakable
                    pp.seplist(keys) do |keydef|
                        pp.text keydef.join(" = ")
                    end
                end
		pp.breakable
		pp.text '}'
            end
        end
    end

    # Generic method that converts a Typelib value into the corresponding Ruby
    # value.
    def self.to_ruby(value)
        if value.respond_to?(:to_ruby)
            value.to_ruby
        else
            value
        end
    end

    convert_from_ruby String, '/std/string' do |value, typelib_type|
        typelib_type.wrap([value.length, value].pack("QA#{value.length}"))
    end
    convert_from_ruby TrueClass, '/bool' do |value, typelib_type|
        Typelib.from_ruby(1, typelib_type)
    end
    convert_from_ruby FalseClass, '/bool' do |value, typelib_type|
        Typelib.from_ruby(0, typelib_type)
    end
    convert_from_ruby String, '/char' do |value, typelib_type|
        Typelib.from_ruby(value[0], typelib_type)
    end
    specialize_model '/bool' do
        def to_ruby(value)
            value == 1
        end
    end
    specialize '/bool' do
        def to_ruby
            super == 1
        end
    end
    specialize '/std/string' do
        def to_ruby
            to_byte_array[8..-1]
        end
    end

    def self.load_typelib_plugins
        if !ENV['TYPELIB_RUBY_PLUGIN_PATH'] || (@@typelib_plugin_path == ENV['TYPELIB_RUBY_PLUGIN_PATH'])
            return
        end

        ENV['TYPELIB_RUBY_PLUGIN_PATH'].split(':').each do |dir|
            Dir.glob(File.join(dir, '*.rb')) do |file|
                puts "loading #{file}"
                require file
            end
        end

        @@typelib_plugin_path = ENV['TYPELIB_RUBY_PLUGIN_PATH'].dup
    end
    @@typelib_plugin_path = nil
    

    # In Typelib, a registry contains a consistent set of types, i.e. the types
    # are that are related to each other.
    #
    # As mentionned in the Typelib module documentation, it is better to
    # manipulate value objects from types from the same registry. That is more
    # efficient, as it removes the need to compare the type definitions whenever
    # the values are manipulated together.
    #
    # I.e., it is better to use a global registry to represent all the types
    # used in your application. In case you need to load different registries,
    # that can be achieved by +merging+ them together (which will work only if
    # the type definitions match between the registries).
    class Registry
        TYPE_BY_EXT = {
            ".c" => "c",
            ".cc" => "c",
            ".cxx" => "c",
            ".h" => "c",
            ".hh" => "c",
            ".hxx" => "c",
            ".tlb" => "tlb"
        }
	# Returns the file type as expected by Typelib from 
	# the extension of +file+ (see TYPE_BY_EXT)
	#
	# Raises RuntimeError if the file extension is unknown
        def self.guess_type(file)
	    ext = File.extname(file)
            if type = TYPE_BY_EXT[ext]
		type
            else
                raise "Cannot guess file type for #{file}: unknown extension '#{ext}'"
            end
        end

	# Format +option_hash+ to the form expected by do_import
	# (Yes, I'm lazy and don't want to handles hashes in C)
        def self.format_options(option_hash) # :nodoc:
            option_hash.to_a.collect do |opt|
                if opt[1].kind_of?(Array)
                    if opt[1].first.kind_of?(Hash)
                        [ opt[0].to_s, opt[1].map { |child| format_options(child) } ]
                    else
                        [ opt[0].to_s, opt[1].map { |child| child.to_s } ]
                    end
                elsif opt[1].kind_of?(Hash)
                    [ opt[0].to_s, format_options(opt[1]) ]
                else
                    [ opt[0].to_s, opt[1].to_s ]
                end
            end
        end

        # Shortcut for
        #   registry = Registry.new
        #   registry.import(args)
        #
        # See Registry#import
        def self.import(*args)
            registry = Registry.new
            registry.import(*args)
            registry
        end

        def initialize
            Typelib.load_typelib_plugins
            super
        end

        # Imports the +file+ into this registry. +kind+ is the file format or
        # nil, in which case the file format is guessed by extension (see
        # TYPE_BY_EXT)
	# 
        # +options+ is an option hash. The Ruby bindings define the following
        # specific options:
	# merge:: 
        #   merges +file+ into this repository. If this is false, an exception
        #   is raised if +file+ contains types already defined in +self+, even
        #   if the definitions are the same.
	#
	#     registry.import(my_path, 'auto', :merge => true)
	#
	# The Tlb importer has no options
	#
        # The C importer defines the following options: preprocessor:
        #
	# define:: 
        #   a list of VAR=VALUE or VAR options for cpp
	#     registry.import(my_path, :define => ['PATH=/usr', 'NDEBUG'])
	# include:: 
        #   a list of path to add to cpp's search path
	#     registry.import(my_path, :include => ['/usr', '/home/blabla/prefix/include'])
	# rawflags:: 
        #   flags to be passed as-is to cpp. For instance, the two previous
        #   examples can be written
	#
	#   registry.import(my_path, 'auto',
	#     :rawflags => ['-I/usr', '-I/home/blabla/prefix/include', 
	#                  -DPATH=/usr', -DNDEBUG])
	# debug::
        #   if true, debugging information is outputted on stdout, and the
        #   preprocessed output is kept.
        #
        # merge::
        #   load the file into its own registry, and merge the result back into
        #   this one. If it is not set, types defined in +file+ that are already
        #   defined in +self+ will generate an error, even if the two
        #   definitions are the same.
	#
        def import(file, kind = 'auto', options = {})
	    file = File.expand_path(file)
            if !kind || kind == 'auto'
                kind    = Registry.guess_type(file)
            end
            if kind.respond_to?(:call)
                return kind.call(self, file, kind, options)
            end

            do_merge = 
                if options.has_key?('merge') then options.delete('merge')
                elsif options.has_key?(:merge) then options.delete(:merge)
                else true
                end

            options = Registry.format_options(options)

            do_import(file, kind, do_merge, options)
        end

        # Resizes the given type to the given size, while updating the rest of
        # the registry to keep it consistent
        #
        # In practice, it means it modifies the compound field offsets and
        # sizes, and modifies the array sizes so that it matches the new sizes.
        #
        # +type+ must either be a type class or a type name, and to_size the new
        # size for it.
        #
        # See #resize to resize multiple types in one call.
        def resize_type(type, to_size)
            resize(type => to_size)
        end

        # Resize a set of types, while updating the rest of the registry to keep
        # it consistent
        #
        # In practice, it means it modifies the compound field offsets and
        # sizes, and modifies the array sizes so that it matches the new sizes.
        #
        # The given type map must be a mapping from a type name or type class to
        # the new size for that type.
        #
        # See #resize to resize multiple types in one call.
        def resize(typemap)
            new_sizes = typemap.map do |type, size|
                if type.respond_to?(:name)
                    [type.name, size]
                else
                    [type.to_str, size]
                end
            end

            do_resize(new_sizes)
            nil
        end

	# Exports the registry in the provided format, into a Ruby string. The
	# following formats are allowed as +format+:
	# 
	# +tlb+:: Typelib's own XML format
	# +idl+:: CORBA IDL
	# 
	# +options+ is an option hash, which is export-format specific. See the C++
	# documentation of each exporter for more information.
	def export(kind, options = {})
            options = Registry.format_options(options)
            do_export(kind, options)
	end

        # Export the registry into Typelib's own XML format
        def to_xml
            export('tlb')
        end
    end

    # This module is used to extend base Ruby types so that they behave like
    # their corresponding Typelib types 
    #
    # I.e. it must be possible to do
    #
    #   structure.time.seconds = 10
    #
    # while, still, having the option of doing
    #
    #   structure.time => Time instance
    module DynamicWrapperBase
        def to_ruby
            @ruby_object
        end
        def to_typelib
            @typelib_object
        end

        def method_missing(m, *args, &block)
            if @typelib_object.respond_to?(m)
                return @typelib_object.send(m, *args, &block)
            end
            return @ruby_object.respond_to?(m)
        end
    end

    def self.DynamicWrapper(ruby_object, typelib_object)
        ruby_object.extend DynamicWrapperBase
        ruby_object.instance_variable_set(:@ruby_object,    ruby_object)
        ruby_object.instance_variable_set(:@typelib_object, typelib_object)
        ruby_object
    end
end

require 'typelib_ruby'

if Typelib.with_dyncall?
module Typelib
    # An opened C library
    class Library
	# The file name of this library
	attr_reader :name
	# The type registry for this library
        attr_reader :registry

	class << self
	    private :new
	end

	# Open the library at +libname+, associated with the type registry
	# +registry+. This returns a Library object.
        #
        # If no registry a given, an empty one is created.
        #
        # If auto_unload is true (the default), the shared object gets unloaded
        # when the Library object is deleted. Otherwise, it will never be
        # unloaded.
	def self.open(libname, registry = nil, auto_unload = true)
	    libname = File.expand_path(libname)
	    lib = wrap(libname, auto_unload)
            registry ||= Registry.new
	    lib.instance_variable_set("@name", libname)
	    lib.instance_variable_set("@registry", registry)
	    lib
	end
    end

    # A function found in a Typelib::Library. See Library#find
    class Function
	# The library in which this function is defined
	attr_reader :library
	# The function name
	attr_reader :name

	# The return type of this function, or nil if there is no return value
	attr_reader :return_type
	# The set of argument types.
	attr_reader :arguments
	# The set of argument indexes which contain returned data. See #modifies and #returns.
	attr_reader :returned_arguments

	def initialize(library, name)
	    @library = library
	    @name = name
	    @arguments = []
	    @returned_arguments = []
	    @arity = 0
	end

	# Specifies that this function returns a value of type +typename+. The
	# first call to +returns+ specifies the return value of the function
	# (in the C sense).  Subsequent calls specify that the following
	# argument is of type +typename+, and that the argument is a buffer
	# whose sole purpose is to be filled by the function call. In this case,
	# the buffer does not have to be given to #call: the Function object will create
	# one on the fly and #call will return it.
	#
	# For instance, the following standard C function:
	#
	#   int gettimeofday(struct timeval* tv, struct timezone* tz);
	#
	# Is wrapped using
	#
	#   gettimeofday = libc.find('gettimeofday').
	#	returns('int').
	#	returns('struct timeval*').
	#	with_arguments('struct timezone*')
	#
	# And called using
	#
	#   status, time = gettimeofday.call(nil)
	#
	# If the function does not have a return type but *has* a returned argument,
	# the return type must be explicitely specified as 'nil':
	#
	#   my_function.returns(nil).returns('int*')
	#
	def returns(typename)
	    if typename
		type = library.registry.build(typename)
		if type.null?
		    type = nil
		end
	    end

	    if defined? @return_type
		if !type
		    raise ArgumentError, "null type specified as argument"
		end

		@arguments << type
		@returned_arguments << @arguments.size
	    elsif typename
		@return_type = type
	    else
		@return_type = nil
	    end
	    self
	end

	# Specify the type of the following arguments
	def with_arguments(*typenames)
	    types = typenames.map { |n| library.registry.build(n) }
	    @arguments.concat(types)
	    @arity += typenames.size
	    self
	end

	# Specify that the following argument is a buffer which both provides
	# an argument to the function *and* will be modified by the function.
	# For instance, the select standard C function would be wrapped as
	# follows:
	#
	#   select = libc.find('select').
	#	returns('int').modifies('fd_set*').
	#	modifies('fd_set*').modifies('fd_set*').
	#	modifies('struct timeval*')
	#
	# and can then be used with:
	#
	#   status, read, write, except, timeout = 
	#	select.call(read, write, except, timeout)
	#
	# A feature of this library is the possibility to automatically build
	# memory buffers from Ruby values. So, for instance, the following C
	# function
	#
	#   void my_function(int* value);
	#
	# can be used as follows:
	#
	#   my_function = lib.wrap('my_function').modifies('int*')
	#
	#   new_value = my_function.call(5)
	#
	# The library will then automatically convert the Ruby integer '5' into
	# a C memory buffer of type 'int' and return the new Ruby value from
	# this buffer (new_value is a Ruby integer).
	def modifies(typename)
	    @arguments << library.registry.build(typename)
	    @returned_arguments << -@arguments.size
	    @arity += 1
	    self
	end

	# True if this function returns some value (either a return type or
	# some arguments which are also output values)
	def returns_something?; @return_type || !@returned_arguments.empty? end

	# How many arguments #call expects
	attr_reader :arity

	# Calls the function with +args+ for arguments
	def call(*args)
	    filtered_args, vm = prepare_call(args)
	    perform_call(filtered_args, vm)
	end

	alias :[] :call
	# Checks that +args+ is a valid set of arguments for this function
	def filter(*args); Typelib.filter_function_args(args, self) end
	alias :check :filter

	# Returns a CompiledCall object which binds this function to the
	# given argument. See CompiledCall#call
	def compile(*args)
	    filtered_args, vm = prepare_call(args)
	    CompiledCall.new(self, filtered_args, vm)
	end

	def prepare_call(args) # :nodoc:
	    filtered_args = Typelib.filter_function_args(args, self)
	    vm = prepare_vm(filtered_args)
	    return filtered_args, vm
	end

	def perform_call(filtered_args, vm) # :nodoc:
	    retval = vm.call(self)
	    return unless returns_something?

	    # Get the return array
	    ruby_returns = []
	    if return_type
		if MemoryZone === retval
		    ruby_returns << return_type.wrap(retval.to_ptr)
		else
		    ruby_returns << retval
		end
	    end

	    for index in returned_arguments
		ary_idx = index.abs - 1

		value = filtered_args[ary_idx]
		type  = arguments[ary_idx]

		if type < ArrayType
		    ruby_returns << type.wrap(value)
		else
		    ruby_returns << type.deference.wrap(value).to_ruby
		end
	    end

            if ruby_returns.size == 1
                return ruby_returns.first
            else
                return ruby_returns
            end
	end

    end

    # A CompiledCall object is a Function on which some arguments have already
    # been bound
    class CompiledCall
	def initialize(function, filtered_args, vm)
	    @function, @filtered_args, @vm = function, filtered_args, vm
	end

	def call
	    @function.perform_call(@filtered_args, @vm)
	end
    end

    # Implement Typelib's argument handling
    # This method filters a particular argument given the user-supplied value and 
    # the argument expected type. It raises TypeError if +arg+ is of the wrong type
    def self.filter_argument(arg, expected_type) # :nodoc:
	if !(expected_type < IndirectType) && !(Kernel.immediate?(arg) || Kernel.numeric?(arg))
	    raise TypeError, "#{arg.inspect} cannot be used for #{expected_type.name} arguments"
	end
   
	filtered =  if expected_type < IndirectType
			if MemoryZone === arg
			    arg
			elsif Type === arg
			    filter_value_arg(arg, expected_type)
                        elsif arg.nil?
                            expected_type.create_null
			elsif expected_type.deference.name == "/char" && arg.respond_to?(:to_str)
			    # Ruby strings ARE null-terminated
			    # The thing which is not checked here is that there is no NULL bytes
			    # inside the string.
			    arg.to_str.to_memory_ptr
			end
		    end

	if !filtered && (Kernel.immediate?(arg) || Kernel.numeric?(arg))
	    filtered = filter_numeric_arg(arg, expected_type)
	end

	if !filtered
          raise TypeError, "cannot use #{arg.inspect} for a #{expected_type.inspect} argument. Object ID for argument #{arg.class.object_id}, object ID for expected type #{expected_type.object_id}"
	end
	filtered
    end

    # Initializes +expected_type+ from +arg+, where +arg+ can either be a value
    # of expected_type, a value that can be casted into a value of
    # expected_type, or a Ruby value that can be converted into a value of
    # +expected_type+.
    def self.from_ruby(arg, expected_type)      
        if arg.kind_of?(expected_type) 
            return arg
        elsif arg.class < Type && arg.class.casts_to?(expected_type)
            arg.cast(expected_type)
        elsif converter = convertions[[arg.class, expected_type.name]]
            converter.call(arg, expected_type)
        elsif expected_type.respond_to?(:from_ruby)
            expected_type.from_ruby(arg)
        end
    end

    # Creates an array of objects that can safely be passed to function call mechanism
    def self.filter_function_args(args, function) # :nodoc:
        # Check we have the right count of arguments
        if args.size != function.arity
            raise ArgumentError, "#{function.arity} arguments expected, got #{args.size}"
        end
        
        # Create a Value object to collect the data we'll get
        # from output-only arguments
        function.returned_arguments.each do |index|
            next unless index > 0
            ary_idx = index - 1

	    type = function.arguments[ary_idx]
	    buffer = if type < ArrayType then type.new
		     elsif type < PointerType then type.deference.new
		     else
			 raise ArgumentError, "unexpected output type #{type.name}"
		     end

            args.insert(ary_idx, buffer) # works because return_spec is sorted
        end

	args.each_with_index do |arg, idx|
	    args[idx] = filter_argument(arg, function.arguments[idx])
	end
    end

    # A raw, untyped, memory zone
    class MemoryZone
	def to_s
	    "#<MemoryZone:#{object_id} ptr=0x#{address.to_s(16)}>"
	end
    end
end
end

