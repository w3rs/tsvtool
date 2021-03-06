module Reciprocity.Command.Builtin where

import ReciprocityPrelude
import Reciprocity.Base
import Reciprocity.Record
import Reciprocity.Command.Base

import Data.Char (isSpace)
import Data.Conduit.Internal (zipSources)

import Data.Text          (replace)

-- * Cat

data CmdCat = CmdCat {} deriving (Show)
instance IsCommand CmdCat where

  commandInfo = CmdInfo {
    cmdDesc = "Concatenate inputs",
    cmdParser = do
      pure CmdCat
  }

  runCommand _ = do
    env <- ask
    liftIO $ runConduitRes $ withInputSourcesH env $ \hsources -> catWithHeaderC env hsources .| stdoutC

-- * Merge

data CmdMerge = CmdMerge { mergeKey :: Subrec } deriving (Show)

instance IsCommand CmdMerge where
  commandInfo = CmdInfo {
    cmdDesc = "Merge ordered inputs into ordered output",
    cmdParser = do
      mergeKey <- keyOpt
      pure CmdMerge{..}
    }
  runCommand CmdMerge{..} = do
    env <- ask
    let merge = mergeSourcesOn $ getSubrec env mergeKey
    runConduitRes $ withInputSourcesH env $ \headersSources -> let
      ((mheader:_), sources) = unzip headersSources in
      (yieldMany mheader >> merge (mapLinesC sources)) .| joinLinesC .| stdoutC
    where

-- * Join

data CmdJoin = CmdJoin {
  cmdJoinKey :: Subrec,
  cmdJoinValue :: Subrec,
  cmdJoinOuterLeft :: Bool,
  cmdJoinOuterRight :: Bool
  } deriving (Show)

instance IsCommand CmdJoin where

  commandInfo = CmdInfo {
    cmdDesc = "Join ordered headerless inputs on common key",
    cmdParser = do
      cmdJoinKey <- keyOpt
      cmdJoinValue <- valueOpt
      cmdJoinOuterLeft <- switch (short '1' ++ help "Outer join on first input")
      cmdJoinOuterRight <- switch (short '2' ++ help "Outer join on second input")
      return (CmdJoin{..})
    }

  runCommand CmdJoin{..} = do
    env <- ask
    let [s1, s2] = map (.| linesCE) $ inputSources env
    runConduitRes $ joinCE (joinOpts env) [s1, s2] .| unlinesCE .| stdoutC
    where
    {-# INLINE joinOpts #-}
    joinOpts :: Env ByteString -> JoinOpts ByteString ByteString _
    joinOpts env@Env{..} = JoinOpts {
      joinOuterLeft = cmdJoinOuterLeft,
      joinOuterRight = cmdJoinOuterRight,
      joinKey = getSubrec env cmdJoinKey,
      joinValue = getSubrec env cmdJoinValue,
      joinCombine = case cmdJoinKey of
        [] -> headEx
        _  -> \(map unLineString -> [k,v1,v2]) -> LineString $ k ++ envSep ++ v1 ++ envSep ++ v2
      }

-- * Diff

data CmdDiff = CmdDiff {
  } deriving (Show)

instance IsCommand CmdDiff where

  commandInfo = CmdInfo {
    cmdDesc = "Fieldwise diff. Show only differing fields",
    cmdParser = pure CmdDiff
    }

  runCommand CmdDiff = do
    env <- ask
    let [src1, src2] = map (.| linesC) $ inputSources env
    runConduitRes $ zipSources src1 src2 .| concatMapC diffs .| unlinesBSC .| stdoutC
    where
    diffs (l1, l2) = if
      | l1 == l2 -> []
      | length vals1 /= length vals2 -> [joinTsvFields $ "0": take 1 vals1]
      | otherwise -> [
        joinTsvFields [encodeUtf8 (tshow ix), val1, val2]
        | (ix, val1, val2) <- zip3 [0 :: Int ..] vals1 vals2
        , val1 /= val2
      ]
      where
      vals1 = splitTsvLine l1
      vals2 = splitTsvLine l2

-- * Split

data CmdSplit = CmdSplit {
  splitKey :: Subrec,
  splitPartition, splitMkdir, splitCompress :: Bool,
  splitBuckets  :: Natural,
  splitTemplate :: Text
  } deriving (Show)
instance IsCommand CmdSplit where

  commandInfo = CmdInfo {
    cmdDesc = "Split into multiple files: put records having key KEY into file INPUT.KEY",
    cmdParser = do
      splitKey <- keyOpt
      splitPartition <- switch (long "partition" ++
        help "MapReduce partition mode: split into buckets determined by hash of the key")
      splitMkdir <- switch (long "mkdir" ++ help "Create directories for output files")
      splitCompress <- switch (long "compress" ++ short 'z' ++ help "Compress output with gzip")
      splitBuckets <- natOpt
        (long "buckets" ++ help "Number of buckets" ++ value 1)
      splitTemplate <- textOpt id (long "out" ++ value "{s}.{filename}" ++ help "Output filepath template (appended to input filename)")
      return CmdSplit{..}
    }

  runCommand (CmdSplit{..}) = do
    env <- ask
    let getKey = getSubrec env splitKey
    let split file source = runConduitRes $ withHeader env source $
          \h -> linesCE .| splitCE (toFile getKey file) splitMkdir splitCompress h
    sequence_ $ zipWith split (inputFiles env) (inputSources env)
    where
    toFile fk inFile = \rec -> unpack $ setValue $ value rec
      where
      setValue val = replace "{s}" val template
      template = replace "{filename}" (pack $ takeFileName inFile) splitTemplate
      value = if
        | splitPartition -> tshow . bucket (fromIntegral splitBuckets) . unLineString . fk
        | otherwise -> omap (\c -> if isSpace c then '.' else c) . decodeUtf8 . unLineString . fk
    -- let (base, ext) = splitExtension inFile in base +? BC.unpack (fk rec) +? ext
    -- x +? y = if null x then y else if null y then x else x ++ "." ++ y

-- * Replace

data CmdLookup = CmdLookup {
  lookupDictFiles :: [FilePath],
  lookupInputSubrec, lookupKey, lookupReplacement :: Subrec,
  lookupKeep :: Bool,
  lookupInvert :: Bool
  } deriving Show
instance IsCommand CmdLookup where
  commandInfo = CmdInfo {
    cmdDesc = "Intersect with keyset, or replace subrecord using key-value dict",
    cmdParser = do
      lookupInputSubrec <- subrecOpt $ short 'i' ++ help "Input subrecord to lookup"
      lookupKey <- subrecOpt $ long "key" ++ short 'k' ++ help "Key subrecord in dict/keyset files"
      lookupReplacement <- subrecOpt $ long "val" ++ short 'v' ++
        help "Value subrecord in dict file. If not set, no replacement is performed."
      lookupKeep <- switch $ long "outer" ++
        help "In replacement mode, keep all unmatched input records"
      lookupInvert <- switch $ short 'c' ++ long "invert" ++
        help "Select only non-matching lines (set complement)"
      lookupDictFiles <- some $ argument str $ metavar "DICT_FILE..."
      return CmdLookup{..}
    }

  runCommand (CmdLookup{..}) = do
    env <- ask
    c <- if null lookupReplacement
      then do
        -- TODO: replace dict with set?
        dict <- mconcat <$> (runConduitRes $ mapM (getDict env) lookupDictFiles)
        let p = (if lookupInvert then not else id) . (`member` keysSet dict)
        return $ filterCE $ p . getSubrec env lookupInputSubrec
      else do
        dict <- mconcat <$> (runConduitRes $ mapM (getDict env) lookupDictFiles)
        let inputSub = subrec env lookupInputSubrec
        return $ dictReplaceCE lookupKeep dict inputSub
    runConduitRes $ withInputSourcesH env $ \headersSources -> let
      ((mheader:_), sources) = unzip headersSources in
      (do
        yieldManyWithEOL mheader
        sequence_ [ s .| linesCE .| c .| unlinesCE | s <- sources]
      ) .| stdoutC
    where
    getDict env file = sourceFile file .| linesCE .| foldlCE
      (\m s -> uncurry insertMap (getKeyValue env lookupKey lookupReplacement s) m)
      (asHashMap mempty)
