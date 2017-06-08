{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# OPTIONS_GHC -fno-warn-orphans  #-}
module Miso.Router where

import qualified Data.ByteString.Char8 as BS
import           Data.Proxy
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Data.Text.Encoding
import           GHC.TypeLits
import           Network.HTTP.Types
import           Network.URI
import           Servant.API
import           Web.HttpApiData

import           Miso.Html hiding (text)

-- | DMJ: Why is this shared ? Only API type should be shared

-- | Router terminator.
-- The 'HasRouter' instance for 'View' finalizes the router.
--
-- Example:
--
-- > type MyApi = "books" :> Capture "bookId" Int :> View

-- | 'Location' is used to split the path and query of a URI into components.
data Location = Location
  { locPath  :: [Text]
  , locQuery :: Query
  } deriving (Show, Eq, Ord)

-- | When routing, the router may fail to match a location.
-- Either this is an unrecoverable failure,
-- such as failing to parse a query parameter,
-- or it is recoverable by trying another path.
data RoutingError = Fail | FailFatal deriving (Show, Eq, Ord)

-- | A 'Router' contains the information necessary to execute a handler.
data Router a where
  RChoice       :: Router a -> Router a -> Router a
  RCapture      :: FromHttpApiData x => (x -> Router a) -> Router a
  RQueryParam   :: (FromHttpApiData x, KnownSymbol sym)
                   => Proxy sym -> (Maybe x -> Router a) -> Router a
  RQueryParams  :: (FromHttpApiData x, KnownSymbol sym)
                   => Proxy sym -> ([x] -> Router a) -> Router a
  RQueryFlag    :: KnownSymbol sym
                   => Proxy sym -> (Bool -> Router a) -> Router a
  RPath         :: KnownSymbol sym => Proxy sym -> Router a -> Router a
  RPage         :: a -> Router a

-- | This is similar to the @HasServer@ class from @servant-server@.
-- It is the class responsible for making API combinators routable.
-- 'RouteT' is used to build up the handler types.
-- 'Router' is returned, to be interpretted by 'routeLoc'.
class HasRouter layout where
  -- | A route handler.
  type RouteT layout a :: *
  -- | Transform a route handler into a 'Router'.
  route :: Proxy layout -> Proxy a -> RouteT layout a -> Router a

instance (HasRouter x, HasRouter y) => HasRouter (x :<|> y) where
  type RouteT (x :<|> y) a = RouteT x a :<|> RouteT y a
  route _ (a :: Proxy a) ((x :: RouteT x a) :<|> (y :: RouteT y a))
    = RChoice (route (Proxy :: Proxy x) a x) (route (Proxy :: Proxy y) a y)

instance (HasRouter sublayout, FromHttpApiData x) =>
  HasRouter (Capture sym x :> sublayout) where
  type RouteT (Capture sym x :> sublayout) a = x -> RouteT sublayout a
  route _ a f = RCapture (route (Proxy :: Proxy sublayout) a . f)

instance (HasRouter sublayout, FromHttpApiData x, KnownSymbol sym)
         => HasRouter (QueryParam sym x :> sublayout) where
  type RouteT (QueryParam sym x :> sublayout) a = Maybe x -> RouteT sublayout a
  route _ a f = RQueryParam (Proxy :: Proxy sym)
    (route (Proxy :: Proxy sublayout) a . f)

instance (HasRouter sublayout, FromHttpApiData x, KnownSymbol sym)
         => HasRouter (QueryParams sym x :> sublayout) where
  type RouteT (QueryParams sym x :> sublayout) a = [x] -> RouteT sublayout a
  route _ a f = RQueryParams
    (Proxy :: Proxy sym)
    (route (Proxy :: Proxy sublayout) a . f)

instance (HasRouter sublayout, KnownSymbol sym)
         => HasRouter (QueryFlag sym :> sublayout) where
  type RouteT (QueryFlag sym :> sublayout) a = Bool -> RouteT sublayout a
  route _ a f = RQueryFlag
    (Proxy :: Proxy sym)
    (route (Proxy :: Proxy sublayout) a . f)

instance (HasRouter sublayout, KnownSymbol path)
         => HasRouter (path :> sublayout) where
  type RouteT (path :> sublayout) a = RouteT sublayout a
  route _ a page = RPath
    (Proxy :: Proxy path)
    (route (Proxy :: Proxy sublayout) a page)

instance HasRouter (View a) where
  type RouteT (View a) x = x
  route _ _ = RPage

instance HasLink (View a) where
  type MkLink (View a) = MkLink (Get '[] ())
  toLink _ = toLink (Proxy :: Proxy (Get '[] ()))

-- | Use a handler to route a 'Location'.
-- Normally 'runRoute' should be used instead, unless you want custom
-- handling of string failing to parse as 'URI'.
runRouteLoc :: forall layout a. HasRouter layout
         => Location -> Proxy layout -> RouteT layout a -> Either RoutingError a
runRouteLoc loc layout page =
  let routing = route layout (Proxy :: Proxy a) page
  in routeLoc loc routing

-- | Use a handler to route a location, represented as a 'String'.
-- All handlers must, in the end, return @m a@.
-- 'routeLoc' will choose a route and return its result.
runRoute :: forall layout a. HasRouter layout
         => URI -> Proxy layout -> RouteT layout a -> Either RoutingError a
runRoute uri layout page = runRouteLoc (uriToLocation uri) layout page

-- | Use a computed 'Router' to route a 'Location'.
routeLoc :: Location -> Router a -> Either RoutingError a
routeLoc loc r = case r of
  RChoice a b -> do
    case routeLoc loc a of
      Left Fail -> routeLoc loc b
      Left FailFatal -> Left FailFatal
      Right x -> Right x
  RCapture f -> case locPath loc of
    [] -> Left Fail
    capture:paths ->
      case parseUrlPieceMaybe capture of
        Nothing -> Left FailFatal
        Just x -> routeLoc loc { locPath = paths } (f x)
  RQueryParam sym f -> case lookup (BS.pack $ symbolVal sym) (locQuery loc) of
    Nothing -> routeLoc loc $ f Nothing
    Just Nothing -> Left FailFatal
    Just (Just text) -> case parseQueryParamMaybe (decodeUtf8 text) of
      Nothing -> Left FailFatal
      Just x -> routeLoc loc $ f (Just x)
  RQueryParams sym f -> maybe (Left FailFatal) (routeLoc loc . f) $ do
    ps <- sequence $ snd <$> Prelude.filter
      (\(k, _) -> k == BS.pack (symbolVal sym)) (locQuery loc)
    sequence $ (parseQueryParamMaybe . decodeUtf8) <$> ps
  RQueryFlag sym f -> case lookup (BS.pack $ symbolVal sym) (locQuery loc) of
    Nothing -> routeLoc loc $ f False
    Just Nothing -> routeLoc loc $ f True
    Just (Just _) -> Left FailFatal
  RPath sym a -> case locPath loc of
    [] -> Left Fail
    p:paths -> if p == T.pack (symbolVal sym)
      then routeLoc (loc { locPath = paths }) a
      else Left Fail
  RPage a -> Right a

-- | Convert a 'URI' to a 'Location'.
uriToLocation :: URI -> Location
uriToLocation uri = Location
  { locPath = decodePathSegments $ BS.pack (uriPath uri)
  , locQuery = parseQuery $ BS.pack (uriQuery uri)
  }