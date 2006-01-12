#ifndef __TYPEBUILDER_H__
#define __TYPEBUILDER_H__

#include <string>
#include <list>

#include "typemodel.hh"

namespace Typelib
{
    class Registry;

    class TypeBuilder
    {
        std::string m_basename;
        Type const* m_type;

        struct Modifier
        {
            Type::Category category;
            int size; // Size of an array, deference count on multi-dim pointers
        };
        typedef std::list<Modifier> ModifierList;
        typedef std::pair<const Type*, ModifierList> TypeSpec;

        static TypeSpec parse(const Registry& registry, const std::string& full_name);
        static const Type& build(Registry& registry, const TypeSpec& spec);

        Registry& m_registry;

    public:
        /** Initializes the type builder
         * This constructor builds the canonical name based on @c base
         * an gets its initial type from @c registry. It throws 
         * Undefined(typename) if @c base is not defined
         *
         * @arg registry the registry to act on
         * @arg base the base type
         */
        TypeBuilder(Registry& registry, const std::list<std::string>& base);

        /** Initializes the type builder
         * @arg registry the registry to act on
         * @arg base_type the base type
         */
        TypeBuilder(Registry& registry, const Type* base_type);

        /** Builds a level-deferenced pointer of the current type */
        void addPointer(int level);
        /** Builds an array of @c size element of the current type */
        void addArray(int size);

        /** Get the current type */
        const Type& getType() const;

        static const Type* build(Registry& registry, const std::string& full_name);
        static std::string getBaseTypename(const std::string& full_name);
        static const Type* getBaseType(const Registry& registry, const std::string& full_name);
};
};

#endif
