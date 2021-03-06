{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

module ES
  ( initServer
  , createIndex
  , checkIndices
  , queryIndex
  , queryBulk
  , createBulk
  , flushIndex
  , countIndex
  , closeIndex
  ) where

import           Control.Arrow ((&&&))
import           Control.Monad ((<=<), forM, forM_, unless)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Reader (ask, asks)
import qualified Data.Aeson as J
import qualified Data.Aeson.Encoding as JE
import qualified Data.Aeson.Types as J (Parser, parseEither, parseMaybe, typeMismatch)
import qualified Data.Attoparsec.ByteString as AP
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy.Char8 as BSLC
import           Data.Default (def)
import           Data.Either (partitionEithers)
import           Data.Foldable (fold)
import qualified Data.HashMap.Strict as HM
import           Data.IORef (newIORef, readIORef, writeIORef)
import           Data.List (find)
import           Data.Maybe (mapMaybe)
import           Data.Monoid ((<>))
import           Data.Proxy (Proxy)
import           Data.String (IsString)
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Network.HTTP.Client as HTTP
import           Network.HTTP.Types.Header (hAccept, hContentType)
import           Network.HTTP.Types.Method (StdMethod(GET, PUT, POST), renderStdMethod)
import qualified Network.HTTP.Types.URI as HTTP (Query)
import qualified Network.URI as URI
import           Text.Read (readEither)
import qualified Waimwork.Config as C

import Monoid
import JSON
import Field
import Catalog
import Global

initServer :: C.Config -> IO HTTP.Request
initServer conf = HTTP.parseUrlThrow (conf C.! "server")

class Body a where
  bodyRequest :: a -> HTTP.RequestBody
  bodyContentType :: a -> Maybe BS.ByteString

instance Body () where
  bodyRequest _ = HTTP.requestBody HTTP.defaultRequest
  bodyContentType _ = Nothing

instance Body J.Encoding where
  bodyRequest = HTTP.RequestBodyLBS . JE.encodingToLazyByteString
  bodyContentType _ = Just "application/json"

instance Body J.Value where
  bodyRequest = bodyRequest . J.toEncoding
  bodyContentType _ = Just "application/json"

instance Body B.Builder where
  bodyRequest = HTTP.RequestBodyLBS . B.toLazyByteString
  bodyContentType _ = Just "application/x-ndjson"

instance Body EmptyJSON where
  bodyRequest EmptyJSON = HTTP.RequestBodyBS "{}"
  bodyContentType _ = Just "application/json"

elasticSearch :: (Body b, J.FromJSON r, Show r) => StdMethod -> [String] -> HTTP.Query -> b -> M r
elasticSearch meth url query body = do
  glob <- ask
  let req = globalES glob
      req' = HTTP.setQueryString query req
        { HTTP.method = renderStdMethod meth
        , HTTP.path = HTTP.path req <> BS.intercalate "/" (map (BSC.pack . URI.escapeURIString URI.isUnescapedInURIComponent) url)
        , HTTP.requestHeaders = maybe id ((:) . (,) hContentType) (bodyContentType body)
            $ (hAccept, "application/json")
            : HTTP.requestHeaders req
        , HTTP.requestBody = bodyRequest body
        }
  liftIO $ do
    {-
    print $ HTTP.path req'
    case bodyRequest body of
      HTTP.RequestBodyBS b -> print b
      HTTP.RequestBodyLBS b -> print b
      _ -> return ()
    -}
    r <- either fail return . (J.parseEither J.parseJSON <=< AP.eitherResult)
      =<< HTTP.withResponse req' (globalHTTP glob) parse
    -- print r
    return r
  where
  parse r = AP.parseWith (HTTP.responseBody r) (J.json <* AP.endOfInput) BS.empty

catalogURL :: Catalog -> [String]
catalogURL Catalog{ catalogStore = ~CatalogES{ catalogIndex = idxn } } =
  [T.unpack idxn]

defaultSettings :: Catalog -> J.Object
defaultSettings cat = HM.fromList
  [ "index" J..= J.object (
    [ "number_of_shards" J..= (clusterSize * min 100 (maybe 2 (succ . (`div` (clusterSize * docsPerShard))) (catalogCount cat)))
    , "number_of_replicas" J..= J.Number 1
    , "refresh_interval" J..= J.Number (-1)
    , "max_docvalue_fields_search" J..= (8 + length (catalogFields cat))
    ] ++ case catalogSort cat of
      [] -> []
      s ->
        [ "sort.field" J..= map J.String s
        , "sort.order" J..= map (const $ J.String "asc") s
        ])
  ] where
  -- elastic search cluster size to optimize for (should really be determined dynamicaly)
  clusterSize = 4
  -- target number of docs per shard
  docsPerShard = 100000000

createIndex :: Catalog -> M J.Value
createIndex cat@Catalog{ catalogStore = ~CatalogES{..} } = elasticSearch PUT [T.unpack catalogIndex] [] $ JE.pairs $
     "settings" J..= mergeJSONObject catalogSettings (defaultSettings cat)
  <> "mappings" .=*
    (  "dynamic" J..= J.String "strict"
    <> "_source" .=* ("enabled" J..= (catalogStoreField == ESStoreSource))
    <> "properties" J..= HM.map field (catalogFieldMap cat))
  where
  field f = J.object
    [ "type" J..= (fieldType f :: Type)
    , "store" J..= (catalogStoreField == ESStoreStore)
    ]

checkIndices :: M (HM.HashMap Simulation String)
checkIndices = do
  isdev <- asks globalDevMode
  indices <- elasticSearch GET ["*"] [] ()
  HM.mapMaybe (\cat -> either Just (const Nothing) $ J.parseEither (catalog isdev cat) indices)
    <$> asks (catalogMap . globalCatalogs)
  where
  catalog isdev ~cat@Catalog{ catalogStore = CatalogES{ catalogIndex = idxn } } =
    parseJSONField idxn (idx isdev cat)
  idx :: Bool -> Catalog -> J.Value -> J.Parser ()
  idx isdev cat = J.withObject "index" $ \i -> do
    sets <- i J..: "settings" >>= (J..: "index")
    ro <- sets J..:? "blocks" >>= maybe (return Nothing) (J..:? "read_only") >>= maybe (return False) boolish
    unless (isdev || ro) $ fail "open (not read_only)"
    parseJSONField "mappings" (mapping $ catalogFields cat) i
  mapping :: Fields -> J.Value -> J.Parser ()
  mapping fields = J.withObject "mapping" $ parseJSONField "properties" $ J.withObject "properties" $ \ps ->
    forM_ fields $ \field -> parseJSONField (fieldName field) (prop field) ps
  prop :: Field -> J.Value -> J.Parser ()
  prop field = J.withObject "property" $ \p -> do
    t <- p J..: "type"
    unless (t == fieldType field) $ fail $ "incorrect field type; should be " ++ show (fieldType field)
  boolish :: J.Value -> J.Parser Bool
  boolish (J.Bool b) = return b
  boolish (J.String "true") = return True
  boolish (J.String "false") = return False
  boolish v = J.typeMismatch "bool" v

scrollTime :: IsString s => s
scrollTime = "60s"

data HistogramInterval a
  = HistogramInterval
    { histogramInterval :: a
    , _histogramRanges :: [(a, a)] -- (log, exp)
    }

queryIndexScroll :: Bool -> Catalog -> Query -> M J.Value
queryIndexScroll scroll cat@Catalog{ catalogStore = ~CatalogES{ catalogStoreField = store } } Query{..} = do
  hists <- gethists
  amend hists <$> elasticSearch GET
    (catalogURL cat ++ ["_search"])
    (mwhen scroll $ [("scroll", Just scrollTime)])
    (JE.pairs $
       (mwhen (queryOffset > 0) $ "from" J..= queryOffset)
    <> (mwhen (queryLimit  > 0 || not scroll) $ "size" J..= queryLimit)
    <> "sort" `JE.pair` JE.list (\(f, a) -> JE.pairs (fieldName f J..= if a then "asc" else "desc" :: String)) (querySort ++ [(def{ fieldName = "_doc" },True)])
    <> (case store of
      ESStoreSource -> "_source"
      ESStoreValues -> "docvalue_fields"
      ESStoreStore -> "stored_fields") J..= map fieldName queryFields
    <> "query" .=* (if querySample < 1
      then \q -> ("function_score" .=* ("query" .=* q
        <> "random_score" .=* foldMap (\s -> "seed" J..= s <> "field" J..= ("_seq_no" :: String)) querySeed
        <> "boost_mode" J..= ("replace" :: String)
        <> "min_score" J..= (1 - querySample)))
      else id) filts
    <> "track_total_hits" J..= J.Bool True
    <> aggs hists queryAggs)
  where
  -- find all histogram fields and divide them into those with range queries and those without
  -- if a field appears in multiple histograms, we use the same (arbitrary) size for all
  -- this could be easily fixed, but would require more complex histsize results
  (histunks, histbnds) = partitionEithers $ map (\h@(f, t, n) ->
      maybe (Left h) (Right . (, t, n)) $
        find (\q -> fieldName f == fieldName q && unTypeValue isbnd (fieldType q)) queryFilter)
    $ foldMap histFields queryAggs
  isbnd (FilterRange (Just _) (Just _)) = True
  isbnd _ = False
  histFields (QueryHist f n t l) = (f, t, n) : foldMap histFields l
  histFields _ = []

  -- pre-query ranges of histogram fields without bounds if necesary
  gethists = HM.fromList . mapMaybe histsize . (histbnds ++) <$> if null histunks then return [] else
    fold . J.parseMaybe fillhistbnd <$> elasticSearch GET
      (catalogURL cat ++ ["_search"]) []
      (JE.pairs $
        "size" J..= J.Number 0
      <> "query" .=* filts
      <> "aggs" .=* foldMap (\(f, _, _) ->
           ("0" <> fieldName f) .=* ("min" .=* field f)
        <> ("1" <> fieldName f) .=* ("max" .=* field f))
        histunks)
  -- resolve bounds in pre-query result
  fillhistbnd j = do
    jaggs <- j J..: "aggregations"
    forM histunks $ \(f, t, n) -> do
      let val a = traverseTypeValue (maybe (fail "bnd value") return) . parseTypeJSONValue (fieldType f)
            =<< (J..: "value") =<< jaggs J..: a
      lb <- val ("0" <> fieldName f)
      ub <- val ("1" <> fieldName f)
      return (liftFilterValue f $ FilterRange (Just lb) (Just ub), t, n)
  -- calculate bucket size from range and count
  histsize :: (FieldSub Filter Proxy, Bool, Word) -> Maybe (T.Text, TypeValue HistogramInterval)
  histsize (f, t, n) = case fieldType f of
    Double    (FilterRange (Just l) (Just u)) -> q Double    l u
    Float     (FilterRange (Just l) (Just u)) -> q Float     l u
    HalfFloat (FilterRange (Just l) (Just u)) -> q HalfFloat l u
    Long      (FilterRange (Just l) (Just u)) -> i Long      l u
    Integer   (FilterRange (Just l) (Just u)) -> i Integer   l u
    Short     (FilterRange (Just l) (Just u)) -> i Short     l u
    Byte      (FilterRange (Just l) (Just u)) -> i Byte      l u
    _ -> fail "invalid hist"
    where
    r :: (Num t, Ord t) => (forall f . f t -> TypeValue f) -> (t -> [(t, t)]) -> t -> Maybe (T.Text, TypeValue HistogramInterval)
    r c l s = return (fieldName f, c $ HistogramInterval s' (l s')) where
      s' | s > 0 = s
         | otherwise = 1
    q :: (Floating t, Ord t, Enum t) => (forall f . f t -> TypeValue f) -> t -> t -> Maybe (T.Text, TypeValue HistogramInterval)
    q c l u
      | t && l > 0 = r c (\s -> map (id &&& exp) $ take (fromIntegral $ succ n) $ enumFromThenTo ll (ll + s) lu) $ (lu - ll) / realToFrac n
      | otherwise = r c (const []) $ (u - l) / realToFrac n
      where
      ll = log l
      lu = log u
    i :: Integral t => (forall f . f t -> TypeValue f) -> t -> t -> Maybe (T.Text, TypeValue HistogramInterval)
    i c l u
      | t = fail "log hist on int"
      | otherwise = r c (const []) $ (u - l + n' - 1) `div` n' where n' = fromIntegral n

  -- add hist field sizes (widths) to final result
  amend :: HM.HashMap T.Text (TypeValue HistogramInterval) -> J.Value -> J.Value
  amend h (J.Object o) | not (HM.null h') = J.Object $ HM.insert "histsize" (J.toJSON h') o where
    h' = HM.map (fmapTypeValue1 histogramInterval) h
  amend _ j = j

  filts = "bool" .=* ("filter" `JE.pair` JE.list (\f -> JE.pairs $ unTypeValue (term f) $ fieldType f) queryFilter)
  term f (FilterEQ v) = "term" .=* (fieldName f J..= v)
  term f (FilterRange l u) = "range" .=* (fieldName f .=* (bound "gte" l <> bound "lte" u)) where
    bound t = foldMap (t J..=)
  agg :: HM.HashMap T.Text (TypeValue HistogramInterval) -> QueryAgg -> J.Series
  agg _ (QueryStats f) = fieldName f .=* ((if isTermsField f then "terms" else "stats") .=* field f)
  agg _ (QueryPercentiles f p) = "pct" .=* ("percentiles" .=* (field f <> "percents" J..= p))
  agg h (QueryHist f _ _ a)
    | Just v <- HM.lookup (fieldName f) h = "hist" .=*
      (unTypeValue (hist f) v <> aggs h a)
    | otherwise = mempty
  aggs _ [] = mempty
  aggs h a = "aggs" .=* foldMap (agg h) a
  hist f (HistogramInterval i []) = "histogram" .=* (field f
    <> "interval" J..= i
    <> "min_doc_count" J..= J.Number 1)
  hist f (HistogramInterval _ l) = "range" .=* (field f
    <> "ranges" `JE.pair` JE.list id (range l))
  range ((lx,x):r@((_,y):_)) = JE.pairs ("from" J..= x <> "to" J..= y <> "key" J..= show lx) : range r
  range _ = []

  field = ("field" J..=) . fieldName

queryIndex :: Catalog -> Query -> M J.Value
queryIndex = queryIndexScroll False

scrollSearch :: T.Text -> M J.Value
scrollSearch sid = elasticSearch GET ["_search", "scroll"] [] $ JE.pairs $
     "scroll" J..= J.String scrollTime
  <> "scroll_id" J..= sid

queryBulk :: Catalog -> Query -> M (IO (Word, V.Vector [J.Value]))
queryBulk cat@Catalog{ catalogStore = CatalogES{ catalogStoreField = store } } query@Query{..} = do
  glob <- ask
  sidv <- liftIO $ newIORef Nothing
  return $ do
    sid <- readIORef sidv
    res <- runGlobal glob $ maybe
      (queryIndexScroll True cat query)
      scrollSearch
      sid
    (sid', rows) <- either fail return $ J.parseEither parse res
    writeIORef sidv $ Just sid'
    return rows
  where
  parse = J.withObject "query" $ \q -> (,)
    <$> q J..: "_scroll_id"
    <*> parseJSONField "hits" (J.withObject "hits" $ \hits -> (,)
      <$> (hits J..: "total" >>= (J..: "value"))
      <*> parseJSONField "hits" (J.withArray "hits" $
        V.mapM $ J.withObject "hit" $ case store of
          ESStoreSource ->
            parseJSONField "_source" $ J.withObject "source" $ \d ->
              return $ map (\f -> HM.lookupDefault J.Null (fieldName f) d) queryFields
          _ ->
            parseJSONField "fields" $ J.withObject "fields" $ \d ->
              return $ map (\f -> unsingletonJSON $ HM.lookupDefault J.Null (fieldName f) d) queryFields) hits)
      q

createBulk :: Catalog -> [(String, J.Series)] -> M ()
createBulk cat@Catalog{ catalogStore = ~CatalogES{} } docs = do
  r <- elasticSearch POST (catalogURL cat ++ ["_bulk"]) [] body
  -- TODO: ignore 409
  unless (HM.lookup "errors" (r :: J.Object) == Just (J.Bool False)) $ fail $ "createBulk: " ++ BSLC.unpack (J.encode r)
  where
  body = foldMap doc docs
  doc (i, d) = J.fromEncoding (J.pairs $ "create" .=* ("_id" J..= i))
    <> nl <> J.fromEncoding (J.pairs d) <> nl
  nl = B.char7 '\n'

flushIndex :: Catalog -> M (J.Value, J.Value)
flushIndex Catalog{ catalogStore = ~CatalogES{ catalogIndex = idxn } } = (,)
  <$> elasticSearch POST ([T.unpack idxn, "_refresh"]) [] EmptyJSON
  <*> elasticSearch POST ([T.unpack idxn, "_flush"]) [] EmptyJSON

newtype ESCount = ESCount{ esCount :: Word } deriving (Show)
instance J.FromJSON ESCount where
  parseJSON = fmap ESCount <$> J.withObject "count" (parseJSONField "count" $ \case
    J.String t -> either fail return $ readEither (T.unpack t)
    v -> J.parseJSON v)

countIndex :: Catalog -> M Word
countIndex Catalog{ catalogStore = ~CatalogES{ catalogIndex = idxn } } =
  sum . map esCount <$> elasticSearch GET (["_cat", "count", T.unpack idxn]) [] EmptyJSON

closeIndex :: Catalog -> M J.Value
closeIndex Catalog{ catalogStore = ~CatalogES{ catalogIndex = idxn } } =
  elasticSearch PUT ([T.unpack idxn, "_settings"]) [] $ JE.pairs $
    "index" .=* ("blocks" .=* ("read_only" J..= True))
