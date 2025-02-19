||| Interface and utilities for marshalling Idris2 values from JSON
||| via an intermediate `Value` representation.
|||
||| For regular algebraic data types, implementations can automatically
||| be derived using elaborator reflection (see module `Derive.FromJSON`)
|||
||| Operators and functionality strongly influenced by Haskell's aeson
||| library
module JSON.Simple.FromJSON

import Derive.Prelude
import JSON.Parser
import JSON.Simple.Option
import JSON.Simple.ToJSON
import Text.FC
import Text.ParseError

%language ElabReflection

%default total

--------------------------------------------------------------------------------
--          Types
--------------------------------------------------------------------------------

public export
data JSONPathElement = Key String | Index Bits32

%runElab derive "JSONPathElement" [Show,Eq]

public export
JSONPath : Type
JSONPath = List JSONPathElement

public export
JSONErr : Type
JSONErr = (JSONPath,String)

public export
Result : Type -> Type
Result = Either JSONErr

public export
Parser : Type -> Type -> Type
Parser v a = v -> Either JSONErr a

public export
orElse : Either a b -> Lazy (Either a b) -> Either a b
orElse r@(Right _) _ = r
orElse _           v = v

public export
(<|>) : Parser v a -> Parser v a -> Parser v a
f <|> g = \vv => f vv `orElse` g vv

public export
data DecodingErr : Type where
  JErr      : JSONErr -> DecodingErr
  JParseErr : (FileContext,ParseErr)-> DecodingErr

%runElab derive "DecodingErr" [Show,Eq]

public export
DecodingResult : Type -> Type
DecodingResult = Either DecodingErr

--------------------------------------------------------------------------------
--          Error Formatting
--------------------------------------------------------------------------------

||| Format a <http://goessner.net/articles/JsonPath/ JSONPath> as a 'String'
||| which represents the path relative to some root object.
export
formatRelativePath : JSONPath -> String
formatRelativePath path = format "" path
  where
    isIdentifierKey : List Char -> Bool
    isIdentifierKey []      = False
    isIdentifierKey (x::xs) = isAlpha x && all isAlphaNum xs

    escapeChar : Char -> String
    escapeChar '\'' = "\\'"
    escapeChar '\\' = "\\\\"
    escapeChar c    = singleton c

    escapeKey : List Char -> String
    escapeKey = fastConcat . map escapeChar

    formatKey : String -> String
    formatKey key =
      let chars = fastUnpack key
       in if isIdentifierKey chars then fastPack $ '.' :: chars
          else "['" ++ escapeKey chars ++ "']"

    format : String -> JSONPath -> String
    format pfx []                = pfx
    format pfx (Index idx :: parts) = format (pfx ++ "[" ++ show idx ++ "]") parts
    format pfx (Key key :: parts)   = format (pfx ++ formatKey key) parts

||| Format a <http://goessner.net/articles/JsonPath/ JSONPath> as a 'String',
||| representing the root object as @$@.
export
formatPath : JSONPath -> String
formatPath path = "$" ++ formatRelativePath path

||| Annotate an error message with a
||| <http://goessner.net/articles/JsonPath/ JSONPath> error location.
export
formatError : JSONPath -> String -> String
formatError path msg = "Error in " ++ formatPath path ++ ": " ++ msg

||| Pretty prints a decoding error. In case of a parsing error,
||| this might be printed on several lines.
export
prettyErr : (input : String) -> DecodingErr -> String
prettyErr _ (JErr (p,s))  = formatError p s
prettyErr i (JParseErr (fc,err)) = printParseError i fc err

--------------------------------------------------------------------------------
--          Interface
--------------------------------------------------------------------------------

public export
interface FromJSON a  where
  constructor MkFromJSON
  fromJSON : Parser JSON a

export %inline
decode : FromJSON a => String -> DecodingResult a
decode s =
  let Right json := parseJSON Virtual s | Left err => Left (JParseErr err)
      Right res  := fromJSON json       | Left p   => Left (JErr p)
   in Right res

export %inline
decodeEither : FromJSON a => String -> Either String a
decodeEither s = mapFst (prettyErr s) $ decode s

export %inline
decodeMaybe : FromJSON a => String -> Maybe a
decodeMaybe = either (const Nothing) Just . decode

--------------------------------------------------------------------------------
--          Parsing Utilities
--------------------------------------------------------------------------------

export
typeOf : JSON -> String
typeOf JNull        = "Null"
typeOf (JBool _)    = "Boolean"
typeOf (JNumber _)  = "Number"
typeOf (JString _)  = "String"
typeOf (JArray _)   = "Array"
typeOf (JObject _)  = "Object"

export %inline
fail : String -> Result a
fail s = Left (Nil,s)

typeMismatch : String -> Parser JSON a
typeMismatch expected actual =
  fail $ "expected \{expected}, but encountered \{typeOf actual}"

unexpected : Parser JSON a
unexpected actual = fail $ "unexpected \{typeOf actual}"

export %inline
modifyFailure : (String -> String) -> Result a -> Result a
modifyFailure f = mapFst (map f)

||| If the inner 'Parser' failed, prepend the given string to the failure
||| message.
export %inline
prependFailure : String -> Result a -> Result a
prependFailure = modifyFailure . (++)

export %inline
prependContext : String -> Result a -> Result a
prependContext name = prependFailure "parsing \{name} failed, "

export %inline
prependPath : Result a -> JSONPathElement -> Result a
prependPath r elem = mapFst (\(path,s) => (elem :: path,s)) r

withValue :
     (type : String)
  -> (JSON -> Maybe t)
  -> (name : Lazy String)
  -> Parser t a
  -> Parser JSON a
withValue s get n f val =
  case get val of
    Just v  => f v
    Nothing => prependContext n $ typeMismatch s val

export %inline
withObject : Lazy String -> Parser (List (String,JSON)) a -> Parser JSON a
withObject = withValue "Object" $ \case JObject ps => Just ps; _ => Nothing

export %inline
withBoolean : Lazy String -> Parser Bool a -> Parser JSON a
withBoolean = withValue "Boolean" $ \case JBool b => Just b; _ => Nothing

export %inline
withString : Lazy String -> Parser String a -> Parser JSON a
withString = withValue "String" $ \case JString s => Just s; _ => Nothing

export %inline
eqString : Lazy String -> String -> Parser JSON ()
eqString n s = withString n $ \s' =>
  if s == s' then Right () else fail "expected '\{s}' but got '\{s'}'"

export %inline
withNumber : Lazy String -> Parser Double a -> Parser JSON a
withNumber = withValue "Number" $ \case JNumber d => Just d; _ => Nothing

export
withInteger : Lazy String -> Parser Integer a -> Parser JSON a
withInteger s f =
  withNumber s $ \d =>
    let n := the Integer (cast d)
     in if d == fromInteger n
           then f n
           else fail "not an integer: \{show d}"

export
withLargeInteger : Lazy String -> Parser Integer a -> Parser JSON a
withLargeInteger s f v =
  withInteger s f v `orElse` withString s parseStr v
  where
    parseStr : Parser String a
    parseStr str =
      case parseInteger {a = Integer} str of
        Nothing => fail "not an integer: \{show str}"
        Just n  => f n

export
boundedIntegral :
     Num a
  => Lazy String
  -> (lower : Integer)
  -> (upper : Integer)
  -> Parser JSON a
boundedIntegral s lo up =
  withInteger s $ \n =>
    if n >= lo && n <= up
       then Right $ fromInteger n
       else fail "integer out of bounds: \{show n}"

export
boundedLargeIntegral :
     Num a
  => Lazy String
  -> (lower : Integer)
  -> (upper : Integer)
  -> Parser JSON a
boundedLargeIntegral s lo up =
  withLargeInteger s $ \n =>
    if n >= lo && n <= up
       then Right $ fromInteger n
       else fail "integer out of bounds: \{show n}"

export %inline
withArray : Lazy String -> Parser (List JSON) a -> Parser JSON a
withArray = withValue "Array" $ \case JArray v => Just v; _ => Nothing

export %inline
withArrayN :
     (n : Nat)
  -> Lazy String
  -> Parser (Vect n JSON) a
  -> Parser JSON a
withArrayN n = withValue "Array of length \{show n}" $
  \case JArray v => toVect n v; _ => Nothing

||| See `field`
export
explicitParseField : Parser JSON a -> List (String,JSON) -> Parser String a
explicitParseField p o key =
  case lookup key o of
       Nothing => fail "key \{show key} not found"
       Just v  => p v `prependPath` Key key

||| See `fieldMaybe`
export
explicitParseFieldMaybe :
     Parser JSON a
  -> List (String,JSON)
  -> Parser String (Maybe a)
explicitParseFieldMaybe p o key =
  case lookup key o of
       Nothing    => Right Nothing
       Just JNull => Right Nothing
       Just v     => map Just $ p v `prependPath` Key key

||| See `optField`
export
explicitParseFieldMaybe' :
     Parser JSON a
  -> List (String,JSON)
  -> Parser String a
explicitParseFieldMaybe' p o key =
  case lookup key o of
       Nothing   => p JNull `prependPath` Key key
       Just v    => p v `prependPath` Key key

||| Retrieve the value associated with the given key of an `IObject`.
||| The result is `empty` if the key is not present or the value cannot
||| be converted to the desired type.
|||
||| This accessor is appropriate if the key and value /must/ be present
||| in an object for it to be valid.  If the key and value are
||| optional, use `optField` instead.
export %inline
field : FromJSON a => List (String,JSON) -> Parser String a
field = explicitParseField fromJSON

||| Retrieve the value associated with the given key of an `IObject`. The
||| result is `Nothing` if the key is not present or if its value is `Null`,
||| or `empty` if the value cannot be converted to the desired type.
|||
||| This accessor is most useful if the key and value can be absent
||| from an object without affecting its validity.  If the key and
||| value are mandatory, use `field` instead.
export %inline
fieldMaybe : FromJSON a => List (String,JSON) -> Parser String (Maybe a)
fieldMaybe = explicitParseFieldMaybe fromJSON

||| Retrieve the value associated with the given key of an `IObject`
||| passing on `Null` in case the given key is missing.
|||
||| This differs from `fieldMaybe` in that it can be used with any converter
||| accepting `Null` as an input.
export %inline
optField : FromJSON a => List (String,JSON) -> Parser String a
optField = explicitParseFieldMaybe' fromJSON

--------------------------------------------------------------------------------
--          Implementations
--------------------------------------------------------------------------------

export
FromJSON Void where
  fromJSON v = fail "Cannot parse Void"

export
FromJSON () where
  fromJSON = withArray "()" $
    \case Nil    => Right ()
          _ :: _ => fail "parsing () failed, expected empty list"

export
FromJSON Bool where
  fromJSON = withBoolean "Bool" Right

export
FromJSON Double where
  fromJSON = withNumber "Double" Right

export
FromJSON Bits8 where
  fromJSON = boundedIntegral "Bits8" 0 0xff

export
FromJSON Bits16 where
  fromJSON = boundedIntegral "Bits16" 0 0xffff

export
FromJSON Bits32 where
  fromJSON = boundedIntegral "Bits32" 0 0xffffffff

export
FromJSON Bits64 where
  fromJSON = boundedLargeIntegral "Bits64" 0 0xffffffffffffffff

export
FromJSON Int where
  fromJSON = boundedLargeIntegral "Int" (-0x8000000000000000) 0x7fffffffffffffff

export
FromJSON Int8 where
  fromJSON = boundedLargeIntegral "Int8" (-0x80) 0x7f

export
FromJSON Int16 where
  fromJSON = boundedLargeIntegral "Int16" (-0x8000) 0x7fff

export
FromJSON Int32 where
  fromJSON = boundedLargeIntegral "Int32" (-0x80000000) 0x7fffffff

export
FromJSON Int64 where
  fromJSON = boundedLargeIntegral "Int64" (-0x8000000000000000) 0x7fffffffffffffff

export
FromJSON Nat where
  fromJSON = withLargeInteger "Nat" $ \n =>
    if n >= 0 then Right $ fromInteger n
    else fail #"not a natural number: \#{show n}"#

export
FromJSON Integer where
  fromJSON = withLargeInteger "Integer" Right

export
FromJSON String where
  fromJSON = withString "String" Right

export
FromJSON Char where
  fromJSON = withString "Char" $ \str =>
    case strM str of
      StrCons c "" => Right c
      _            => fail "expected a string of length 1"

export
FromJSON a => FromJSON (Maybe a) where
  fromJSON JNull = Right Nothing
  fromJSON v     = Just <$> fromJSON v

export
FromJSON a => FromJSON (List a) where
  fromJSON = withArray "List" $ traverse fromJSON

export
FromJSON a => FromJSON (List1 a) where
  fromJSON = withArray "List1" $
    \case Nil    => fail "expected non-empty list"
          h :: t => traverse fromJSON (h ::: t)

export
{n : Nat} -> FromJSON a => FromJSON (Vect n a) where
  fromJSON = withArray "Vect \{show n}" $
    \vs => case toVect n vs of
                Just vect => traverse fromJSON vect
                Nothing   => fail "expected list of length \{show n}"

export
FromJSON a => FromJSON b => FromJSON (Either a b) where
  fromJSON = withObject "Either" $ \o =>
               map Left (field o "Left") `orElse`
               map Right (field o "Right")

export
FromJSON a => FromJSON b => FromJSON (a, b) where
  fromJSON = withArray "Pair" $
    \case [x,y] => [| MkPair (fromJSON x) (fromJSON y) |]
          _     => fail "expected a pair of values"

||| Tries to decode a value encoded as a single field object of the given name.
|||
||| This corresponds to the `ObjectWithSingleField` option
||| for encoding sum types.
export
fromSingleField :
     (tpe : Lazy String)
  -> Parser (String,JSON) a
  -> Parser JSON a
fromSingleField n f = withObject n $
  \case [p] => f p
        _   => fail "expected single field object"

||| Tries to decode a value encoded as a two-element array with the given
||| constructor name.
|||
||| This corresponds to the `TwoElemArray` option
||| for encoding sum types.
export
fromTwoElemArray :
     (tpe : Lazy String)
  -> Parser (String,JSON) a
  -> Parser JSON a
fromTwoElemArray n f =
  withArrayN 2 n $ \[x,y] => withString n (\s => f (s,y)) x

||| Tries to decode a value encoded as a tagged object with the given
||| tag and content field, plus tag value.
|||
||| This corresponds to the `TaggedObject` option
||| for encoding sum types.
export
fromTaggedObject :
     (tpe : Lazy String)
  -> (tagField, contentField : String)
  -> Parser (String,JSON) a
  -> Parser JSON a
fromTaggedObject n tf cf f = withObject n $ \o => do
  s <- field o tf
  v <- explicitParseField Right o cf
  f (s,v)
