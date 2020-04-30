# Migrating code to use the @safe API of mysql-native

Starting with version 3.1.0, mysql-native is transitioning to using a fully `@safe` API. This document describes how mysql-native is migrating, and how you can migrate your existing code to the new version.

First, note that the latest version of mysql, while it supports a safe API, is defaulted to supporting the original unsafe API. We highly recommend reading and following the recommendations in this document so you can start using the safe version and be prepared for future changes that will deprecate and remove the unsafe API.

## Why Safe?

*related: please see D's [Memory Safety](https://dlang.org/spec/memory-safe-d.html) page to understand what `@safe` does in D*

Since mysql-native is intended to be a key component of servers that are on the Internet, it must support the capability (even if not required) to be fully `@safe`. In addition, major web frameworks (e.g. [vibe.d](http://code.dlang.org/packages/vibe-d)) and arguably any other program are headed in this direction.

In other words, the world wants memory safe code, and libraries that provide safe interfaces and guarantees will be much more appealing. It's just not acceptable any more for the components of major development projects to be careless about memory safety.

## Roadmap

The intended roadmap for migrating to a safe API is the following:

* v3.1.0 - In this version, the `safe` and `unsafe` packages were introduced, providing a way to specify exactly which API you want to use. The default modules and packges in this version import the `unsafe` versions of the API to maintain full backwards compatibility.
* v4.0.0 - In this version, the `unsafe` versions of the API will be deprecated, meaning you can still use them, but you will get warnings. In addition, the default modules and packages will import the `safe` API.
* Future version (possibly v5.0.0) - In this version, the `unsafe` API will be completely removed, and the `safe` modules now simply publicly import the standard modules. The `mysql.impl` package will be removed.

## The Major Changes

mysql-native until now used the Phobos type `std.variant.Variant` to hold data who's type was unknown at compile time. Unfortunately, since `Variant` can hold *any* type, it must default to having a `@system` postblit/copy constructor, and a `@system` destructor. This means that just copying a `Variant`, passing it as a function parameter, or returning it from a function makes the function doing such things `@system`. This meant that we needed to move from `Variant` to a new type that allows only safe usages, but still maintained the ability to decide types at runtime.

To this end, we used the library [taggedalgebraic](http://code.dlang.org/packages/taggedalgebraic), which supports not only safe call forwarding, but also provides a much more transparent and useful API than Variant. A `TaggedAlgebraic` allows you to limit which types MySQL deals with. This allows better implicit conversion support, and more focused code. It also prevents one from passing in parameter types that are not supported and not finding that out until runtime.

The module `mysql.types` now contains a new type called `MySQLVal`, which should be, for the most part, a drop-in replacement for `Variant` in your code.

### The safe/unsafe API

In some cases, fixing memory safety in mysql-native was as simple as adding a `@safe` tag to the module or functions in the module. These functions and modules should work just as before, but are now callable from `@safe` code.

But for the rest, to achieve full backwards compatibility, we have divided the API into two major sections -- safe and unsafe. The package `mysql.safe` will import all the safe versions of the API, the package `mysql.unsafe` will import the unsafe versions. If you import `mysql`, it will currently point at the unsafe version for backwards compatibility (see [Roadmap](#Roadmap) for details on how this will change).

The following modules have been split into mysql.safe.*modname* and mysql.unsafe.*modname*. Importing mysql.*modname* will currently import the unsafe version for backwards compatibility.
* `mysql.commands`
* `mysql.pool`
* `mysql.result`
* `mysql.prepared`
* `mysql.connection`

Each of these modules in unsafe mode provides the same API as the previous version of mysql. The safe version provides aliases to the original type names for the safe versions of types, and also provides the same functions as before that can be called via safe code. The one exception is in `mysql.safe.commands`, where some functions were for the deprecated `BackwardCompatPrepared`, which will eventually be removed.

If you are currently importing any of the above modules directly, or importing the `mysql` package, a first step to migration is to use the `mysql.safe` package. From there you will find that almost everything works exactly the same.

In addition to these two new packages, we have introduced a package called `mysql.impl`. This package contains the common implementations of the `safe` and `unsafe` modules, and should NOT be directly imported ever. These modules are documented simply because that is where the code lives. But in the version of mysql that removes the `unsafe` API, this package will be removed. You should always use the `unsafe` or `safe` packages instead, which generally publicly import the `impl` modules anyway.

#### Importing both safe and unsafe

It is possible to import some modules using the safe package, and some using the unsafe package in the case where you are gradually migrating to safe versions of your code. However, you should not import the same module from both safe and unsafe packages, as there will be naming conflicts.

For example, if you import from `mysql.safe.result` and `mysql.unsafe.result`, the alias for `Row` will be tied to both `UnsafeRow` and `SafeRow`, resulting in a compilation ambiguity.

But it is definitely possible to import `mysql.unsafe.result` and `mysql.safe.commands`. You may need to use the `safe` or `unsafe` conversion methods on the types to make your code function as desired. See details later on these conversion methods.

### Migrating from Variant to MySQLVal

The module `mysql.types` has been amended to contain the `MySQLVal` type. This type can hold any value type that MySQL supported originally, or a const pointer to such a type (for the purposes of prepared statements), or the value `null`. This is now the type used for all parameters to `query` and `exec` (in the safe API). The `mysql.types` import also provides compatibility shims with `Variant` such as `coerce`, `convertsTo`, `type`, `peek`, and `get` (See the documentation for [Variant](https://dlang.org/phobos/std_variant.html#.VariantN)).

You can examine all the benefits of `TaggedAlgebraic` [here](https://vibed.org/api/taggedalgebraic.taggedalgebraic/TaggedAlgebraic). In particular, the usage of the `kind` member is preferred over using the `type` shim. Note that only safe operations are allowed, so for instance `opBinary!"+"` is not allowed on pointers.

One pitfall of this migration has to do with `Variant`'s ability to represent *any* type -- including `MySQLVal`! If you have declared a variable of type `Variant`, and assign it to a `MySQLVal` result from a row or a query, it will compile, but it will NOT do what you are expecting. This will fail at runtime most likely. It is recommended before switching to the safe API to change those types to `MySQLVal` or use `auto` if possible.

Example:
```D
import mysql.safe;

Variant v = connection.queryValue("SELECT 1 AS `somevar`");
```

This will compile and run, and the resulting variable `v` will be a `MySQLVal` typed as a `MySQLVal.Kind.Int` wrapped in a `Variant`. This is not what you want. In order to fix this, you should either re-type `v` as `MySQLVal` (or use `auto`) or use the `asVariant` function included in `mysql.types`:

```D
import mysql.safe;

// preferred
MySQLVal v = connection.queryValue("SELECT 1 AS `somevar`");
// if necessary
Variant v2 = connection.queryValue("SELECT 1 AS `somevar`").asVariant;
```

One important thing to note is that the internals of mysql-native have all been switched to using `MySQLVal` instead of `Variant`. Only at the shallow API level is `Variant` used to provide the backwards compatible API. So if you do not switch, you will pay the penalty of having the library first construct a `MySQLVal` and then convert that to a `Variant` (or vice versa).

### Row and ResultRange

These two types were tied greatly to `Variant`. As such, they have been rewritten into `SafeRow` and `SafeResultRange` which use `MySQLVal` instead. Thin compatibility wrappers of `UnsafeRow` and `UnsafeResultRange` are available as well, which will convert the values to and from `Variant` as needed. Depending on which API you import `safe` or `unsafe`, these items are aliased to `Row` and `ResultRange` for source compatibility.

However, each of these structures provides `unsafe` and `safe` conversion functions to convert between the two if absolutely necessary. In fact, most of the unsafe API calls that return an `UnsafeRow` or `UnsafeResultRange` are actually `@safe`, since the underlying implementation uses `MySQLVal`. It only becomes unsafe when you try to access a column as a `Variant`.

The following example should compile with both `mysql.safe` and `mysql.unsafe`, but simply use `Variant` or `MySQLVal` as needed:
```D
import mysql;

// assume a database table named 'mapping' with a string 'name' and int 'value'
int getMapping(Connection conn, string name)
{
    Row r = conn.queryRow("SELECT * FROM mapping WHERE name = ?", name);
    assert(r[0].type == typeid(int));
    return r[0].get!int;
}
```
While the safe version provides drop-in compatibility, it is recommended to switch to safe operations instead:

```D
import mysql.safe;

int getMapping(Connection conn, string name) @safe
{
    Row r = conn.queryRow("SELECT * FROM mapping WHERE name = ?", name);
    //assert(r[0].type == typeid(int)); // this would work, but is @system
    assert(r[0].kind == MySQLVal.Kind.Int);
    return r[0].get!int;
}
```

In cases where current code requires the use of `Variant`, you can still use the safe API, and just do a conversion where needed:

```D
import mysql.safe;

struct EstablishedStruct
{
    Variant value;
    int id;
    void fetchFromDatabase(Connection conn)
    {
        // all safe calls except asVariant
        value = conn.queryValue("SELECT value FROM theTable WHERE id = ?", id).asVariant;
    }
}
```

### Prepared

The `Prepared` struct contained support for setting/getting `Variant` parameters. These have been removed, and reimplemented as a `SafePrepared` struct, which uses `MySQLVal` instead. An `UnsafePrepared` wrapper has been provided, and like `Row`/`ResultSequence`, they have `unsafe`, and `safe` conversion functions.

The `mysql.safe.prepared` module will alias `Prepared` as the safe version, and the `mysql.unsafe.prepared` module will alias `Prepared` as the unsafe version.

One other aspect of `Prepared` that is different in the two versions is the `ParameterSpecialization` data. There are now two different such structs, a `SafeParameterSpecialization` and an `UnsafeParameterSpecialization`. The only difference between these two is the `chunkDelegate` being `@safe` or `@system`. If you do not use the `chunkDelegate`, or your delegate is actually `@safe`, then you should opt for the `@safe` API.

### Connection

The Connection class itself has not changed at all, except to add @safe attributes for all methods. However, the `mysql.connection` module contained the functions to generate `Prepared` structs.

The `BackwardsCompatPrepared` struct defined in the original `mysql.connection` module is only available in the unsafe package.

### MySQLPool

`MySQLPool` has been factored into a templated type that has either a fully safe or partly safe API. The only public facing unsafe part was the user-supplied callback function to be called on every connection creation (which therefore made `lockConnection` unsafe). The unsafe version continues to use such a callback method (and is explicitly marked `@system`), whereas the safe version requires a `@safe` callback.

If you do not use this callback mechanism, it is highly recommended that you use the safe API for the pool, as there is no actual difference between the two at that point. It's also very likely that your callback actually is `@safe`, even if you do use one.

### The commands module

The `mysql.commands` module has been factored into 2 versions, a safe and unsafe version. The only differences between these two are where `Variant` is concerned. All query and exec functions that accepted `Variant` explicitly have been reimplemented in the safe version to accept `MySQLVal`. All functions that return `Variant`, `Row` or `ResultRange` have been reimplemented to return `MySQLVal`, `SafeRow`, or `SafeResultRange` respectively. All functions that do not deal with these types are moved to the safe API, and aliased in the unsafe API. This means, as long as you do not use `Variant` explicitly, you should be able to switch over to the safe version of the API without changing your code.

Even in cases where you elect to defer updating code, you can still import the `safe` API, and use `unsafe` conversion functions to keep existing code working. In most cases, this will not be necessary as the API is kept as similar as possible.

## Rcommended Transition Method

We recommend following these steps to transition. In most cases, you should see very little breakage of code:

1. Adjust your imports to import the safe versions of mysql modules. If you import the `mysql` package, instead import the `mysql.safe` package. If you import any of the individual modules listed in the [API](#the-safeunsafe-api) section, use the `mysql.safe.modulename` equivalent instead.
2. Adjust any explicit uses of `Variant` to `MySQLVal` or use `auto` for type inference. Remember that variables typed as `Variant` explicitly will consume `MySQLVal`, so you may not get compiler errors for these, but you will certainly get runtime errors.
3. If there are cases where you cannot stop using `Variant`, use the `asVariant` compatibility shim.
4. Adjust uses of `Variant`'s methods to use the `TaggedAlgebraic` versions. Most important is usage of the `kind` member, as comparing two `TypeInfo` objects is currently `@system`.
5. `MySQLVal` provides a richer experience of type forwarding, so you may be able to relax some of your code that is concerned with first fetching the concrete type from the `Variant`. Notably, `MySQLVal` can access directly members of any of the `std.datetime` types, such as `year`, `month`, or `day`.
6. Report ANY issues with compatibility or bugs to the issue tracker so we may deal with them ASAP. Our intention is to have you be able to use v3.1.0 without having to adjust any code that worked with 3.0.0.
