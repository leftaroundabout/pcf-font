{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
module Graphics.Text.PCF (PCF, PCFGlyph, loadPCF, decodePCF, getPCFGlyph, getGlyphStrings, getPropMap) where

import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import Data.Bits
import Data.Bool
import Data.List
import qualified Data.Map.Strict as M
import Data.Monoid
import Control.Monad
import Data.ByteString.Lazy (ByteString)
import Data.Vector (Vector, (!))
import GHC.Int
import GHC.Exts
import Data.Char
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BC
import qualified Data.ByteString.Lazy as B
import qualified Data.Vector as V
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.Tuple

assert :: Monad m => Bool -> String -> m ()
assert True  = const $ return ()
assert False = fail

allUnique :: Eq a => [a] -> Bool
allUnique [] = True
allUnique (x:xs) = x `notElem` xs && allUnique xs

getGlyphStrings :: PCF -> [ByteString]
getGlyphStrings PCF{..} = B.split 0 $ glyph_names_string $ snd pcf_glyph_names

getPropMap :: PCF -> [(ByteString, Either ByteString Int)]
getPropMap PCF{..} = flip map properties_props $ \Prop{..} ->
        (getPropString prop_name_offset,
         if prop_is_string /= 0 then
             Left $ getPropString prop_value
         else
             Right $ fromIntegral prop_value)
    where
        (_, PROPERTIES{..}) = pcf_properties
        getPropString = B.takeWhile (/= 0) . flip B.drop properties_strings . fromIntegral

getPCFGlyph :: PCF -> Char -> Maybe PCFGlyph
getPCFGlyph PCF{..} c = do
        glyph_index <- fromIntegral <$> IntMap.lookup (ord c) encodings_glyph_indices
        offset      <- fromIntegral <$> (bitmaps_offsets V.!? glyph_index)
        Metrics{..} <- metrics_metrics V.!? glyph_index
        let cols = fromIntegral $ metrics_right_sided_bearings - metrics_left_sided_bearings
            rows = fromIntegral $ metrics_character_ascent + metrics_character_descent
        pitch <- case glyph_padding of
                    1 -> Just $ (cols + 7) `shiftR` 3
                    2 -> Just $ ((cols + 15) `shiftR` 4) `shiftL` 1
                    4 -> Just $ ((cols + 31) `shiftR` 5) `shiftL` 2
                    8 -> Just $ ((cols + 63) `shiftR` 6) `shiftL` 3
                    _ -> Nothing
        let bytes = fromIntegral $ rows * pitch
        return $ PCFGlyph c cols rows glyph_padding (B.take bytes $ B.drop offset bitmaps_data)
    where
        (meta_bitmaps, BITMAPS{..}) = pcf_bitmaps
        (_, METRICS{..})            = pcf_metrics
        (_, BDF_ENCODINGS{..})      = pcf_bdf_encodings
        glyph_padding = fromIntegral $ tableMetaGlyphPad meta_bitmaps

data PCF = PCF { pcf_properties       :: (TableMeta, Table)
               , pcf_accelerators     :: (TableMeta, Table)
               , pcf_metrics          :: (TableMeta, Table)
               , pcf_bitmaps          :: (TableMeta, Table)
               , pcf_ink_metrics      :: (TableMeta, Table)
               , pcf_bdf_encodings    :: (TableMeta, Table)
               , pcf_swidths          :: (TableMeta, Table)
               , pcf_glyph_names      :: (TableMeta, Table)
               , pcf_bdf_accelerators :: (TableMeta, Table)
               }
    deriving (Show)

data PCFGlyph = PCFGlyph { glyph_char :: Char
                         , glyph_width :: Int
                         , glyph_height :: Int
                         , glyph_padding :: Int
                         , glyph_bitmap :: ByteString }
    deriving (Eq)

instance Show PCFGlyph where
    show PCFGlyph{..} = "PCFGlyph {glyph_char = " ++ show glyph_char ++
                        ", glyph_width = " ++ show glyph_width ++
                        ", glyph_height = " ++ show glyph_height ++
                        ", glyph_bitmap = " ++ show glyph_bitmap ++ "}\n" ++

                        (BC.unpack $ mconcat $ map ((<> "\n") . showBits) rs)
        where
            
            rs = rows glyph_bitmap
            rows bs = case B.splitAt pitch bs of
                    (r, "") -> [r]
                    (r, t) -> r : rows t
                    
            pitch = fromIntegral $ case glyph_padding of
                        1 -> (glyph_width + 7) `shiftR` 3
                        2 -> (glyph_width + 15) `shiftR` 4 `shiftL` 1
                        4 -> (glyph_width + 31) `shiftR` 5 `shiftL` 2
                        8 -> (glyph_width + 63) `shiftR` 6 `shiftL` 3

            showBits = B.concatMap (\w -> showBit w 7 <> showBit w 6 <> showBit w 5 <> showBit w 4 <> showBit w 3 <> showBit w 2 <> showBit w 1 <> showBit w 0)
            showBit :: Word8 -> Int -> ByteString
            showBit w i
              | testBit w i = "X"
              | otherwise   = " "

data Prop = Prop { prop_name_offset :: Word32
                 , prop_is_string :: Word8
                 , prop_value :: Word32 }
    deriving (Show, Eq)

data Table = PROPERTIES { properties_props :: [Prop]
                        , properties_strings :: ByteString }
           | BITMAPS { bitmaps_glyph_count :: Word32
                     , bitmaps_offsets :: Vector Word32
                     , bitmaps_sizes :: (Word32, Word32, Word32, Word32)
                     , bitmaps_data :: ByteString }
           | METRICS { metrics_ink_type :: Bool
                     , metrics_compressed :: Bool
                     , metrics_metrics :: Vector Metrics }
           | SWIDTHS { swidths_swidths :: [Word32] }
           | ACCELERATORS { accel_no_overlap :: Bool
                          , accel_constant_metrics :: Bool
                          , accel_terminal_font :: Bool
                          , accel_constant_width :: Bool
                          , accel_ink_inside :: Bool
                          , accel_ink_metrics :: Bool
                          , accel_draw_direction :: Bool
                          -- ^ False = left to right, True = right to left
                          , accel_font_ascent :: Word32
                          , accel_font_descent :: Word32
                          , accel_max_overlap :: Word32
                          , accel_min_bounds :: Metrics
                          , accel_max_bounds :: Metrics
                          , accel_ink_min_max_bounds :: Maybe (Metrics, Metrics)
                          }
           | GLYPH_NAMES { glyph_names_offsets :: [Word32]
                         , glyph_names_string :: ByteString }
           | BDF_ENCODINGS { encodings_cols :: (Word16, Word16)
                           , encodings_rows :: (Word16, Word16)
                           , encodings_default_char :: Word16
                           , encodings_glyph_indices :: IntMap Word16 }
    deriving (Show, Eq)

data Metrics = Metrics  { metrics_left_sided_bearings :: Word16
                        , metrics_right_sided_bearings :: Word16
                        , metrics_character_width :: Word16
                        , metrics_character_ascent :: Word16
                        , metrics_character_descent :: Word16
                        , metrics_character_attributes :: Word16 }
    deriving (Show, Eq)

getPCF :: Get PCF
getPCF = do
    magic <- getByteString 4
    assert (magic == "\1fcp") "Invalid magic number found in PCF header."
    table_count <- getWord32le
    table_metas <- replicateM (fromIntegral table_count) get
    -- Sort table meta data according to table offset in order to avoid backtracking when parsing table contents
    let table_metas_sorted = sortWith tableMetaOffset table_metas
        table_types = map tableMetaType table_metas_sorted
    assert (allUnique table_types) "Multiple PCF tables of the same type is not supported."
    tables <- mapM get_table table_metas_sorted
    let tableMap = flip M.lookup $ M.fromList $ zip table_types $ zip table_metas tables
        pcf = PCF <$> tableMap PCF_PROPERTIES
                  <*> tableMap PCF_ACCELERATORS
                  <*> tableMap PCF_METRICS
                  <*> tableMap PCF_BITMAPS
                  <*> tableMap PCF_INK_METRICS
                  <*> tableMap PCF_BDF_ENCODINGS
                  <*> tableMap PCF_SWIDTHS
                  <*> tableMap PCF_GLYPH_NAMES
                  <*> tableMap PCF_BDF_ACCELERATORS
    maybe (fail "Incomplete PCF given. One or more tables are missing.") return pcf
    where
      isDefaultFormat, isInkBoundsFormat, isAccelWithInkBoundsFormat, isCompressedMetricsFormat :: Word32 -> Bool
      isDefaultFormat = (== 0x00000000) . (.&. 0xFFFFFF00)
      isInkBoundsFormat = (== 0x00000200) . (.&. 0xFFFFFF00)
      isAccelWithInkBoundsFormat = (== 0x00000100) . (.&. 0xFFFFFF00)
      isCompressedMetricsFormat = (== 0x00000100) . (.&. 0xFFFFFF00)

      get_table TableMeta{..} = do
        pos <- bytesRead
        skip $ fromIntegral tableMetaOffset - fromIntegral pos
        pos <- bytesRead
        assert (pos == fromIntegral tableMetaOffset) "Skipping ahead is broken."
        _ <- getWord32le -- Redundant 'format' field.
        let getWord32 = if tableMetaByte then getWord32be else getWord32le
        let getWord16 = if tableMetaByte then getWord16be else getWord16le
        let get_metrics = Metrics <$> getWord16 <*> getWord16 <*> getWord16 <*> getWord16 <*> getWord16 <*> getWord16
        let get_metrics_table ty = do
                assert (isDefaultFormat tableMetaFormat || isCompressedMetricsFormat tableMetaFormat) "Properties table only supports PCF_DEAULT_FORMAT and PCF_COMPRESSED_METRICS."
                metrics <- fmap V.fromList $ if isCompressedMetricsFormat tableMetaFormat then do
                  metrics_count <- getWord16
                  let getWord = fmap (\x -> fromIntegral $ x - 0x80) getWord8
                  replicateM (fromIntegral metrics_count) $
                    Metrics <$> getWord <*> getWord <*> getWord <*> getWord <*> getWord <*> pure 0
                else do
                  metrics_count <- getWord32
                  replicateM (fromIntegral metrics_count) get_metrics
                return $ METRICS ty (isCompressedMetricsFormat tableMetaFormat) metrics
        let get_accelerators_table = 
              ACCELERATORS <$> get <*> get <*> get <*> get <*> get <*> get <*> get
                           <* getWord8 <*> getWord32 <*> getWord32 <*> getWord32 <*> get_metrics <*> get_metrics
                           <*> (if isAccelWithInkBoundsFormat tableMetaFormat then
                                  fmap Just $ (,) <$> get_metrics <*> get_metrics
                                else
                                  pure Nothing)
        table <- case tableMetaType of
          PCF_PROPERTIES -> do
            assert (isDefaultFormat tableMetaFormat)
              "Properties table only supports PCF_DEFAULT_FORMAT."
            nprops <- getWord32
            props <- replicateM (fromIntegral nprops) (Prop <$> getWord32 <*> getWord8 <*> getWord32)
            skip $ (4 - fromIntegral nprops `mod` 4) `mod` 4 -- Insert padding
            string_size <- getWord32
            strings <- getByteString (fromIntegral string_size)
            return $ PROPERTIES props (B.fromStrict strings)
          PCF_ACCELERATORS     -> get_accelerators_table
          PCF_BDF_ACCELERATORS -> get_accelerators_table
          PCF_METRICS     -> get_metrics_table False
          PCF_INK_METRICS -> get_metrics_table True
          PCF_BITMAPS -> do
            glyph_count <- getWord32
            offsets <- V.fromList <$> replicateM (fromIntegral glyph_count) getWord32
            sizes <- (,,,) <$> getWord32 <*> getWord32 <*> getWord32 <*> getWord32
            bitmap_data <- getByteString $ fromIntegral $ case (tableMetaGlyphPad, sizes) of
                                                            (1, (w,_,_,_)) -> w
                                                            (2, (_,x,_,_)) -> x
                                                            (4, (_,_,y,_)) -> y
                                                            (8, (_,_,_,z)) -> z
            return $ BITMAPS glyph_count offsets sizes (B.fromStrict bitmap_data)
          PCF_BDF_ENCODINGS -> do
            cols <- (,) <$> getWord16 <*> getWord16
            rows <- (,) <$> getWord16 <*> getWord16
            default_char <- getWord16
            glyph_indices <-
                flip mapM [fst rows..snd rows] $ \i ->
                    flip mapM [fst cols..snd cols] $ \j -> do
                        encoding_offset <- getWord16
                        return (fromIntegral $ i * 256 + j, encoding_offset)
            return $ BDF_ENCODINGS cols rows default_char (IntMap.fromList $ concat glyph_indices)
          PCF_SWIDTHS -> do
            glyph_count <- getWord32
            SWIDTHS <$> replicateM (fromIntegral glyph_count) getWord32
          PCF_GLYPH_NAMES ->
            GLYPH_NAMES <$> (getWord32 >>= flip replicateM getWord32 . fromIntegral) <*> (getWord32 >>= fmap B.fromStrict . getByteString . fromIntegral)
        pos' <- bytesRead
        -- assert (pos' - pos == fromIntegral tableMetaSize || table == Ignore) $ "Table size not reached: " ++ show (pos' - pos) ++ " /= " ++ show tableMetaSize
        -- ^ Temporary check: table == Ignore
        return table

data PCFMeta = PCFMeta [TableMeta]
    deriving (Show)

instance Binary PCFMeta where
  get = do
    magic <- getByteString 4
    case magic == "\1fcp" of
      True  -> return ()
      False -> error "Invalid magic number found in PCF header."
    table_count <- fromIntegral <$> getWord32le
    PCFMeta <$> replicateM table_count get

  put (PCFMeta table_meta) = do
    putByteString "\1fcp"
    putWord32le $ fromIntegral $ length table_meta
    mapM_ put table_meta

data TableMeta = TableMeta { tableMetaType :: PCFTableType
                           -- ^ Table type
                           , tableMetaFormat :: Word32
                           -- ^ Whole format field for reconstructing
                           , tableMetaGlyphPad :: Word8
                           -- ^ Level of padding applied to glyph bitmaps
                           , tableMetaScanUnit :: Word8
                           -- ^ ?
                           , tableMetaByte :: Bool
                           -- ^ Byte-wise endianess
                           , tableMetaBit :: Bool
                           -- ^ Bit-wise endianess
                           , tableMetaSize :: Word32
                           -- ^ Number of bytes used by the table
                           , tableMetaOffset :: Word32
                           -- ^ Byte offset to table from beginning of file
                           }
    deriving (Show)

instance Binary TableMeta where
  get = do
    table_type <- get
    fmt <- getWord32le
    size <- getWord32le
    offset <- getWord32le
    return $ TableMeta table_type fmt (shiftL 1 $ fromIntegral $ fmt .&. 3) (fromIntegral $ fmt `shiftR` 4 .&. 0x3) (testBit fmt 2) (testBit fmt 3) size offset

  put TableMeta{..} = do
    assert (tableMetaGlyphPad == (shiftL 1 $ fromIntegral $ tableMetaFormat .&. 3))
      "Inconsistent glyph padding in table metadata."
    assert (tableMetaScanUnit == fromIntegral (tableMetaFormat `shiftR` 4 .&. 0x3))
      "Inconsistent scan unit in table metadata."
    assert (tableMetaByte == testBit tableMetaFormat 2)
      "Inconsistent byte-wise endianness in table metadata."
    assert (tableMetaBit == testBit tableMetaFormat 3)
      "Inconsistent bit-wise endianness in table metadata."
    put tableMetaType
    putWord32le tableMetaFormat
    putWord32le tableMetaSize
    putWord32le tableMetaOffset

data PCFTableType = PCF_PROPERTIES
                  | PCF_ACCELERATORS
                  | PCF_METRICS
                  | PCF_BITMAPS
                  | PCF_INK_METRICS
                  | PCF_BDF_ENCODINGS
                  | PCF_SWIDTHS
                  | PCF_GLYPH_NAMES
                  | PCF_BDF_ACCELERATORS
    deriving (Show, Eq, Ord)

instance Binary PCFTableType where
  get = do
    type_rep <- getWord32le
    case type_rep of
      0x001 -> return PCF_PROPERTIES
      0x002 -> return PCF_ACCELERATORS
      0x004 -> return PCF_METRICS
      0x008 -> return PCF_BITMAPS
      0x010 -> return PCF_INK_METRICS
      0x020 -> return PCF_BDF_ENCODINGS
      0x040 -> return PCF_SWIDTHS
      0x080 -> return PCF_GLYPH_NAMES
      0x100 -> return PCF_BDF_ACCELERATORS
      _     -> fail "Invalid PCF table type encountered."

  put type_val = putWord32le $
      case type_val of
        PCF_PROPERTIES       -> 0x001 
        PCF_ACCELERATORS     -> 0x002 
        PCF_METRICS          -> 0x004 
        PCF_BITMAPS          -> 0x008 
        PCF_INK_METRICS      -> 0x010 
        PCF_BDF_ENCODINGS    -> 0x020 
        PCF_SWIDTHS          -> 0x040 
        PCF_GLYPH_NAMES      -> 0x080 
        PCF_BDF_ACCELERATORS -> 0x100 

loadPCF :: FilePath -> IO (Either String PCF)
loadPCF filepath = decodePCF <$> B.readFile filepath

decodePCF :: ByteString -> Either String PCF
decodePCF = either (Left . extract) (Right . extract) . runGetOrFail getPCF
    where
        extract (_,_,v) = v
