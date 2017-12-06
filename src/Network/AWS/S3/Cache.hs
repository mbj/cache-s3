{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- |
-- Module      : Network.AWS.S3.Cache
-- Copyright   : (c) FP Complete 2017
-- License     : BSD3
-- Maintainer  : Alexey Kuleshevich <alexey@fpcomplete.com>
-- Stability   : experimental
-- Portability : non-portable
--
module Network.AWS.S3.Cache (
  runCacheS3
  , L.LogLevel(..)
  , module Network.AWS.S3.Cache.Types
  ) where

import           Control.Lens
import           Control.Monad               (when)
import           Control.Monad.Catch
import           Control.Monad.Logger        as L
import           Control.Monad.Reader
import           Control.Monad.Trans.AWS
import           Control.Monad.Trans.Maybe
import           Data.Monoid                 ((<>))
import           Data.Text                   as T
import           Data.Time
import           Network.AWS.S3.Cache.Local
import           Network.AWS.S3.Cache.Remote
import           Network.AWS.S3.Cache.Stack
import           Network.AWS.S3.Cache.Types
import           System.Exit

import Control.Monad.Trans.Resource (ResourceT)
import Control.Monad.Trans.Control (MonadBaseControl)

-- TODO:
-- * Create new logger instead of modifying anotherone
-- * Formal log level prettier
-- * Add option for turninng off the timestamp
-- | Filter out min log level events and add a timestamp to all events.
formatLogger ::
     L.LogLevel -- ^ Minimum log level
  -> LoggingT m a
  -> LoggingT m a
formatLogger minLogLevel (LoggingT f) =
  LoggingT $ \logger ->
    f $ \loc src level msg ->
      when (level >= minLogLevel) $ do
        now <- getCurrentTime
        logger loc src level ("[cache-s3] - [" <> toLogStr (formatRFC822 now) <> "]: " <> msg)
        when (level == LevelError) $ exitWith (ExitFailure 1)

-- | Format `UTCTime` as a `String`.
formatRFC822 :: UTCTime -> String
formatRFC822 = formatTime defaultTimeLocale rfc822DateFormat


-- | Run the cache action.
run ::
     (MonadBaseControl IO m, MonadIO m)
  => ReaderT r (LoggingT (ResourceT m)) a
  -> L.LogLevel
  -> r
  -> m a
run action minLogLevel conf =
  runResourceT $ runStdoutLoggingT $ formatLogger minLogLevel $ runReaderT action conf


saveCache :: Text -> Compression -> [FilePath] -> L.LogLevel -> Config -> IO ()
saveCache hAlgTxt comp dirs minLogLevel conf = do
  let hashNoSupport sup =
        logErrorN $
        "Hash algorithm '" <> hAlgTxt <> "' is not supported, use one of these instead: " <>
        T.intercalate ", " sup
  run
    (withHashAlgorithm_ hAlgTxt hashNoSupport $ \hAlg ->
       getCacheHandle dirs hAlg comp >>= uploadCache)
    minLogLevel
    conf


restoreCache :: L.LogLevel -> Config -> IO Bool
restoreCache = run (maybe False (const True) <$> runMaybeT (downloadCache restoreFilesFromCache))

mkConfig :: (MonadIO m, MonadCatch m) =>
            CommonArgs -> m Config
mkConfig CommonArgs {..} = do
  envInit <- newEnv Discover
  let env = maybe envInit (\reg -> envInit & envRegion .~ reg) commonRegion
  mGitBranch <- maybe (liftIO $ getBranchName commonGitDir) (return . Just) commonGitBranch
  let objKey = mkObjectKey commonPrefix mGitBranch commonSuffix
  return $ Config commonBucket objKey env


runCacheS3 :: CommonArgs -> Action -> IO ()
runCacheS3 ca@CommonArgs {..} action = do
  let stackSuffix = "stack"
      stackWorkSuffix = stackSuffix <> "-work"
  case action of
    Save (SaveArgs {..}) -> do
      config <- mkConfig ca
      saveCache saveHash saveCompression savePaths commonVerbosity config
    SaveStack (SaveStackArgs {..}) -> do
      stackGlobalPaths <- getStackGlobalPaths stackRoot
      runCacheS3 (ca {commonSuffix = Just stackSuffix}) $
        Save saveArgs {savePaths = savePaths saveArgs ++ stackGlobalPaths}
    SaveStackWork (SaveStackWorkArgs {stackSaveArgs = SaveStackArgs {..}, ..}) -> do
      stackLocalPaths <- getStackWorkPaths stackRoot stackYaml workDir
      runCacheS3 (ca {commonSuffix = Just stackWorkSuffix}) $
        Save saveArgs {savePaths = savePaths saveArgs ++ stackLocalPaths}
    Restore (RestoreArgs {..}) -> do
      config <- mkConfig ca
      restoreSuccessfull <- restoreCache commonVerbosity config
      case (restoreSuccessfull, restoreBaseBranch) of
        (False, Just _) -> do
          let baseObjKey = mkObjectKey commonPrefix restoreBaseBranch commonSuffix
          void $ restoreCache commonVerbosity $ Config commonBucket baseObjKey (config ^. confEnv)
        _ -> return ()
    RestoreStack (RestoreStackArgs {..}) -> do
      when restoreStackUpgrade $ upgradeStack restoreStackRoot
      runCacheS3 (ca {commonSuffix = Just stackSuffix}) (Restore restoreArgs)
    RestoreStackWork args -> do
      runCacheS3 (ca {commonSuffix = Just stackWorkSuffix}) (Restore args)
    Clear -> mkConfig ca >>= run deleteCache commonVerbosity
    ClearStack ->
      mkConfig (ca {commonSuffix = Just stackSuffix}) >>= run deleteCache commonVerbosity
    ClearStackWork ->
      mkConfig (ca {commonSuffix = Just stackWorkSuffix}) >>= run deleteCache commonVerbosity