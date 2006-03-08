/***********************************************************************************
 *
 * Wrapping of the Registry class
 *
 */


static 
void registry_free(void* ptr) { delete reinterpret_cast<Registry*>(ptr); }

static
VALUE registry_alloc(VALUE klass)
{
    Registry* registry = new Registry;
    return Data_Wrap_Struct(klass, 0, registry_free, registry);
}


static
VALUE registry_do_get(VALUE self, VALUE name)
{
    Registry& registry = rb2cxx::object<Registry>(self);
    Type const* type = registry.get( StringValuePtr(name) );

    if (! type) return Qnil;
    return cxx2rb::type_wrap(*type, self);
}

static
VALUE registry_do_build(VALUE self, VALUE name)
{
    Registry& registry = rb2cxx::object<Registry>(self);
    Type const* type = registry.build( StringValuePtr(name) );

    if (! type) 
        rb_raise(rb_eTypeError, "invalid type %s", StringValuePtr(name));
    return cxx2rb::type_wrap(*type, self);
}

static
VALUE registry_alias(VALUE self, VALUE name, VALUE aliased)
{
    Registry& registry = rb2cxx::object<Registry>(self);

    int error;
    try { 
	registry.alias(StringValuePtr(aliased), StringValuePtr(name)); 
	return self;
    }
    catch(BadName)   { error = 0; }
    catch(Undefined) { error = 1; }
    switch(error)
    {
	case 0: rb_raise(rb_eArgError, "invalid type name %s", StringValuePtr(name));
	case 1: rb_raise(rb_eArgError, "no such type %s", StringValuePtr(aliased));
    }

    // never reached
    assert(false);
}

/* Private method to import a given file in the registry
 * We expect Registry#import to format the arguments before calling
 * do_import
 */
static
VALUE registry_import(VALUE self, VALUE file, VALUE kind, VALUE options)
{
    Registry& registry = rb2cxx::object<Registry>(self);
    
    config_set config;
    if (! NIL_P(options))
    {
        for (int i = 0; i < RARRAY(options)->len; ++i)
        {
            VALUE entry = RARRAY(options)->ptr[i];
            VALUE k = RARRAY(entry)->ptr[0];
            VALUE v = RARRAY(entry)->ptr[1];

            if ( TYPE(v) == T_ARRAY )
            {
                for (int j = 0; j < RARRAY(v)->len; ++j)
                    config.insert(StringValuePtr(k), StringValuePtr( RARRAY(v)->ptr[j] ));
            }
            else
                config.set(StringValuePtr(k), StringValuePtr(v));
        }
    }
        
    // TODO: error checking
    try { PluginManager::load(StringValuePtr(kind), StringValuePtr(file), config, registry); }
    catch(Typelib::ImportError e)
    { rb_raise(rb_eRuntimeError, "cannot import %s: %s", StringValuePtr(file), e.what()); }

    return Qnil;
}

/* Export the given registry into xml
 */
static
VALUE registry_to_xml(VALUE self)
{
    Registry& registry = rb2cxx::object<Registry>(self);
    
    std::string as_xml = PluginManager::save("tlb", registry);
    return rb_str_new(as_xml.c_str(), as_xml.length());
}

