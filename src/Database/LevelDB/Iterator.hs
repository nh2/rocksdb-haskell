-- |
-- Module      : Database.LevelDB.Iterator
-- Copyright   : (c) 2012-2013 The leveldb-haskell Authors
-- License     : BSD3
-- Maintainer  : kim.altintop@gmail.com
-- Stability   : experimental
-- Portability : non-portable
--
-- Iterating over key ranges.
--

module Database.LevelDB.Iterator (
    Iterator
  , createIter
  , releaseIter
  , iterValid
  , iterSeek
  , iterFirst
  , iterLast
  , iterNext
  , iterPrev
  , iterKey
  , iterValue
  , iterGetError
  , mapIter
  , iterItems
  , iterKeys
  , iterValues
  ) where

import           Control.Applicative       ((<$>), (<*>))
import           Control.Concurrent        (MVar, newMVar, withMVar)
import           Control.Exception         (finally,onException)
import           Control.Monad             (when)
import           Control.Monad.IO.Class    (MonadIO (liftIO))
import           Data.ByteString           (ByteString)
import           Data.Maybe                (catMaybes)
import           Foreign
import           Foreign.C.Error           (throwErrnoIfNull)
import           Foreign.C.String          (CString, peekCString)
import           Foreign.C.Types           (CSize)

import           Database.LevelDB.C
import           Database.LevelDB.Internal
import           Database.LevelDB.Types

import qualified Data.ByteString           as BS
import qualified Data.ByteString.Char8     as BC
import qualified Data.ByteString.Unsafe    as BU

-- | Iterator handle
data Iterator = Iterator !IteratorPtr !ReadOptionsPtr !(MVar ()) deriving (Eq)

-- | Create an 'Iterator'.
--
-- The iterator should be released with 'releaseIter'.
--
-- Note that an 'Iterator' creates a snapshot of the database implicitly, so
-- updates written after the iterator was created are not visible. You may,
-- however, specify an older 'Snapshot' in the 'ReadOptions'.
createIter :: MonadIO m => DB -> ReadOptions -> m Iterator
createIter (DB db_ptr _) opts = liftIO $ do
    opts_ptr <- mkCReadOpts opts
    flip onException (freeCReadOpts opts_ptr) $ do
        it_ptr <- throwErrnoIfNull "create_iterator" $
                      c_leveldb_create_iterator db_ptr opts_ptr
        lock   <- newMVar ()
        return $ Iterator it_ptr opts_ptr lock

-- | Release an 'Iterator'.
--
-- The handle will be invalid after calling this action and should no
-- longer be used.
releaseIter :: MonadIO m => Iterator -> m ()
releaseIter iter@(Iterator _ opts _) = iterSync iter $ \iter_ptr ->
    c_leveldb_iter_destroy iter_ptr `finally` freeCReadOpts opts

-- | An iterator is either positioned at a key/value pair, or not valid. This
-- function returns /true/ iff the iterator is valid.
iterValid :: MonadIO m => Iterator -> m Bool
iterValid iter = iterSync iter $ \iter_ptr -> do
    x <- c_leveldb_iter_valid iter_ptr
    return (x /= 0)

-- | Position at the first key in the source that is at or past target. The
-- iterator is /valid/ after this call iff the source contains an entry that
-- comes at or past target.
iterSeek :: MonadIO m => Iterator -> ByteString -> m ()
iterSeek iter key = iterSync iter $ \iter_ptr ->
    BU.unsafeUseAsCStringLen key $ \(key_ptr, klen) ->
        c_leveldb_iter_seek iter_ptr key_ptr (intToCSize klen)

-- | Position at the first key in the source. The iterator is /valid/ after this
-- call iff the source is not empty.
iterFirst :: MonadIO m => Iterator -> m ()
iterFirst iter = iterSync iter c_leveldb_iter_seek_to_first

-- | Position at the last key in the source. The iterator is /valid/ after this
-- call iff the source is not empty.
iterLast :: MonadIO m => Iterator -> m ()
iterLast iter = iterSync iter c_leveldb_iter_seek_to_last

-- | Moves to the next entry in the source. After this call, 'iterValid' is
-- /true/ iff the iterator was not positioned at the last entry in the source.
--
-- If the iterator is not valid, this function does nothing. Note that this is a
-- shortcoming of the C API: an 'iterPrev' might still be possible, but we can't
-- determine if we're at the last or first entry.
iterNext :: MonadIO m => Iterator -> m ()
iterNext iter = iterSync iter $ \iter_ptr -> do
    valid <- c_leveldb_iter_valid iter_ptr
    when (valid /= 0) $ c_leveldb_iter_next iter_ptr

-- | Moves to the previous entry in the source. After this call, 'iterValid' is
-- /true/ iff the iterator was not positioned at the first entry in the source.
--
-- If the iterator is not valid, this function does nothing. Note that this is a
-- shortcoming of the C API: an 'iterNext' might still be possible, but we can't
-- determine if we're at the last or first entry.
iterPrev :: MonadIO m => Iterator -> m ()
iterPrev iter = iterSync iter $ \iter_ptr -> do
    valid <- c_leveldb_iter_valid iter_ptr
    when (valid /= 0) $ c_leveldb_iter_prev iter_ptr

-- | Return the key for the current entry if the iterator is currently
-- positioned at an entry, ie. 'iterValid'.
iterKey :: MonadIO m => Iterator -> m (Maybe ByteString)
iterKey = flip iterString c_leveldb_iter_key

-- | Return the value for the current entry if the iterator is currently
-- positioned at an entry, ie. 'iterValid'.
iterValue :: MonadIO m => Iterator -> m (Maybe ByteString)
iterValue = flip iterString c_leveldb_iter_value

-- | Check for errors
--
-- Note that this captures somewhat severe errors such as a corrupted database.
iterGetError :: MonadIO m => Iterator -> m (Maybe ByteString)
iterGetError iter = iterSync iter $ \iter_ptr ->
    alloca $ \err_ptr -> do
        poke err_ptr nullPtr
        c_leveldb_iter_get_error iter_ptr err_ptr
        erra <- peek err_ptr
        if erra == nullPtr
            then return Nothing
            else do
                err <- peekCString erra
                return . Just . BC.pack $ err

-- | Map a function over an iterator, advancing the iterator forward and
-- returning the value. The iterator should be put in the right position prior
-- to calling the function.
--
-- Note that this function accumulates the result strictly, ie. it reads all
-- values into memory until the iterator is exhausted. This is most likely not
-- what you want for large ranges. You may consider using conduits instead, for
-- an example see: <https://gist.github.com/adc8ec348f03483446a5>
mapIter :: MonadIO m => (Iterator -> IO a) -> Iterator -> m [a]
mapIter f iter = iterSync iter $ go []
  where
    go acc iter_ptr = do
        valid <- c_leveldb_iter_valid iter_ptr
        if valid == 0
            then return acc
            else do
                val <- f iter
                ()  <- c_leveldb_iter_next iter_ptr
                go (val : acc) iter_ptr

-- | Return a list of key and value tuples from an iterator. The iterator
-- should be put in the right position prior to calling this with the iterator.
--
-- See strictness remarks on 'mapIter'.
iterItems :: (Functor m, MonadIO m) => Iterator -> m [(ByteString, ByteString)]
iterItems iter = catMaybes <$> mapIter iterItems' iter
  where
    iterItems' iter' = do
        mkey <- iterKey iter'
        mval <- iterValue iter'
        return $ (,) <$> mkey <*> mval

-- | Return a list of key from an iterator. The iterator should be put
-- in the right position prior to calling this with the iterator.
--
-- See strictness remarks on 'mapIter'
iterKeys :: (Functor m, MonadIO m) => Iterator -> m [ByteString]
iterKeys iter = catMaybes <$> mapIter iterKey iter

-- | Return a list of values from an iterator. The iterator should be put
-- in the right position prior to calling this with the iterator.
--
-- See strictness remarks on 'mapIter'
iterValues :: (Functor m, MonadIO m) => Iterator -> m [ByteString]
iterValues iter = catMaybes <$> mapIter iterValue iter


--
-- Internal
--

iterString :: MonadIO m
           => Iterator
           -> (IteratorPtr -> Ptr CSize -> IO CString)
           -> m (Maybe ByteString)
iterString iter f = iterSync iter $ \iter_ptr -> do
    valid <- c_leveldb_iter_valid iter_ptr
    if valid == 0
        then return Nothing
        else alloca $ \len_ptr -> do
                 ptr <- f iter_ptr len_ptr
                 if ptr == nullPtr
                     then return Nothing
                     else do
                         len <- peek len_ptr
                         Just <$> BS.packCStringLen (ptr, cSizeToInt len)

iterSync :: MonadIO m => Iterator -> (IteratorPtr -> IO a) -> m a
iterSync (Iterator iter_ptr _ lck) act = liftIO $ withMVar lck go
  where
    go () = act iter_ptr
{-# INLINE iterSync #-}