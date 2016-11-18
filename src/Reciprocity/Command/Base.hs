module Reciprocity.Command.Base (module Reciprocity.Command.Base, module Options.Applicative, module Reciprocity.Conduit) where

import CustomPrelude
import Reciprocity.Base
import Reciprocity.Conduit

import Options.Applicative hiding ((<>))
import           System.Directory             (getHomeDirectory)

data CmdInfo c = CmdInfo {
  cmdDesc   :: Text,
  cmdParser :: Parser c
  }

class IsCommand c where
  runCommand :: c -> ReaderT (Env ByteString) IO ()
  commandInfo :: CmdInfo c

data Command = forall a. (Show a, IsCommand a) => Command a
deriving instance Show Command

-- * Option parsing

type OptParser a = Mod OptionFields a -> Parser a

fileOpt :: OptParser FilePath
fileOpt mods = option str (mods ++ metavar "FILE")

textOpt :: Textual s => (s -> a) -> OptParser a
textOpt parse = option (parse . pack <$> str)

natOpt :: OptParser Natural
natOpt mods = option auto (mods ++ metavar "N")

subrecOpt :: Mod OptionFields (Pair (Maybe Natural)) -> Parser Subrec
subrecOpt mods = many $ textOpt (parse . splitSeq "-") (mods ++ metavar "FIELD|FROM-|-TO|FROM-TO")
  where
  parse :: [String] -> Pair (Maybe Natural)
  parse = \case
    [i] -> dupe $ field i
    ["", i] -> (Nothing, field i)
    [i, ""] -> (field i, Nothing)
    [i, j] -> (field i, field j)
    _ -> error "subrecOpt: unrecognized format"
  field = Just . pred . read

keyOpt :: Parser Subrec
keyOpt = subrecOpt (long "key" ++ short 'k' ++ help "Key subrecord")

valueOpt :: Parser Subrec
valueOpt = subrecOpt (long "val" ++ help "Value subrecord")

funOpt :: Mod OptionFields Text -> Parser Text
funOpt mods = textOpt id (mods ++ metavar "FUN" ++ value "")

-- * directory stuff

getRootDir :: IO FilePath
getRootDir = (</> ".reciprocity") <$> getHomeDirectory