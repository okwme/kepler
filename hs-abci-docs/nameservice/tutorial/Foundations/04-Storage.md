---
title: Foundations - Storage
---

# Database

ABCI applications depend on some kind of merkelized storage in order to achieve consensus on a valid application state. The SDK has two database options to interpret `StoreEffs`, an in-memory [avl-auth](https://github.com/oscoin/avl-auth) option as well as a persisted [iavl](https://github.com/tendermint/iavl) option.

# Stores

The most convenient way to partition a key-value store is by heavy use of prefixes -- for example, if you want to separate each module's keyspace, you can use prefix all of the keys that it manages by the module's unique name. If you want to partition storage within a module, say for a list or mapping, you can again use prefixes to create a unique keyspace.

The definition of a `Store` is a unique keyspace. Implementation wise, it is effectively a list of prefixes to concatenate when creating keys. There are currently 6 ways of creating Stores:

1. From a `KeyRoot`, which basically defines a top level Store.
2. Using the `nestStore` function to mount one Store in another.
3. By creating a `Var`, which creates a keyspace with exactly one key.
4. By creating an `Array`, which creates a keyspace whose keys are type `Word64`.
5. By creating a `Map k v`, which creates a keyspace whose keys are type `k`.
6. By creating a `List`, which creates a linked list whose keyspace is internal.


Because a Store is a unique keyspace, it allows us to build a typed key-value storage on top of the raw ByteString interface. This is achieved by adding a phantom namespace type to the Store type and declaring an instance of the `IsKey` class:


~~~ haskell ignore
data Store ns = Store
  { storePathFromRoot :: [ByteString]
  }

class RawKey k where
  rawKey :: Iso' k BS.ByteString

class RawKey k => IsKey k ns where
  type Value k ns :: *
~~~

# Example

Let's take the example of the `Auth` module which is responsible for maintaining a mapping `Address -> Account`. To declare the mapping, we first need to make a namespace and a root storage for the module:

~~~ haskell ignore
data AuthNamespace

store :: Store AuthNamespace
store = makeStore $ KeyRoot "auth"
~~~


We then need to make a new keyspace for our accounts mapping, which looks like

~~~ haskell ignore
data AccountsMapKey = AccountsMapKey

instance RawKey AccountsMapKey where
    rawKey = iso (const "accounts") (const AccountsMapKey)

instance IsKey AccountsMapKey AuthNamespace where
  type Value AccountsMapKey AuthNamespace = Map Address Account
~~~

This tells the compiler that the `AccountsMapKey` key type can only be used to access the mapping `Map Address Account`, it cannot be used to query any other types.

We can then declare the mapping itself like

~~~ haskell ignore
accountsMap :: Map Address Account
accountsMap = makeMap AccountsMapKey store
~~~

This both creates the mapping and mounts it inside of our module level store. The effect of this is that if you wanted to query the underlying raw key-value store for the account associated to the address `0xdeadbeef`, then the actual key looks something like

~~~ haskell ignore
encodeUtf8 "auth" <> encodeUtf8 "accounts" <> bytesFromHex "0xdeafbeef"
~~~

While writing apps inside the SDK you do not need to worry about the explicit prefixing since everything is taken care of for you. However, if you are querying for state via an ABCI `query` message, the `key` field that is returned in the response will contain this full path. In the above example, if you wanted to recover the address from the key, you would need to know the prefixes that were applied.
