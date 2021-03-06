{-# LANGUAGE OverloadedStrings , QuasiQuotes , PackageImports #-}

-- This module defines the main function to handle the messages that comes from users (web or device users).
module Handlers
    ( handleMessage
    , parsMessage
    , setMessageValue
    ) where

import Database.Persist.Postgresql
import Data.Aeson.Types
import Data.Aeson
import Data.Conduit.Pool
import Data.Default
import Data.IORef
import Data.Monoid                        ((<>))
import Data.Text                          (Text,pack,unpack,empty)
import Data.Text.Encoding
import qualified Data.HashMap.Strict      as HM
import qualified "unordered-containers" Data.HashSet    as HS
import qualified Data.Map                 as M
import qualified Data.ByteString.Lazy     as BL
import qualified Data.ByteString          as BS
import Control.Applicative
import Control.Monad                      (mzero,when)
import Control.Monad.Logger
import Control.Monad.Trans.Resource       (runResourceT)
import Network.PushNotify.Gcm
import Network.PushNotify.Mpns
import Network.PushNotify.General
import Control.Concurrent.STM             (atomically)
import Control.Concurrent.STM.TChan       (TChan, writeTChan)
import Blaze.ByteString.Builder.Char.Utf8 (fromText)
import Connect4
import DataBase
import Extra

runDBAct p a = runResourceT . runNoLoggingT $ runSqlPool a p

setMessageValue :: MsgFromPlayer -> Value
setMessageValue m = let message = case m of
                               Cancel         -> [(pack "Cancel" .= pack "")]
                               Movement mov   -> [(pack "Movement" .= (pack $ show mov) )]
                               NewGame usr    -> [(pack "NewGame" .= usr)]
                               Winner  usr    -> [(pack "Winner" .= usr)]
                    in (Object $ HM.fromList message)

getPushNotif :: Value -> PushNotification
getPushNotif (Object o) = def {gcmNotif  = Just $ def { data_object = Just o } }
getPushNotif _          = def

parsMsg :: Value -> Parser MsgFromPlayer
parsMsg (Object v) = setMsg <$>
                       v .:? "Cancel"     <*>
                       v .:? "Movement"   <*>
                       v .:? "NewGame"
parsMsg _          = mzero

parsMessage :: Value -> Maybe MsgFromPlayer
parsMessage = parseMaybe parsMsg

setMsg :: Maybe Text -> Maybe Text -> Maybe Text -> MsgFromPlayer
setMsg (Just _) _ _ = Cancel
setMsg _ (Just a) _ = Movement ((read $ unpack a) :: Int)
setMsg _ _ (Just a) = NewGame a

handleMessage :: Pool Connection -> WebUsers -> PushManager -> Identifier -> Text -> MsgFromPlayer -> IO ()
handleMessage pool webUsers man id1 user1 msg = do
    case msg of
      Cancel       -> do--Cancel
          mId2 <- getOpponentId user1
          case mId2 of
            Just (id2,_) -> sendMessage Cancel id2
            _            -> return ()
          deleteGame user1

      Movement mov -> do--New Movement
          mId2 <- getOpponentId user1
          game <- getGame user1
          case (mId2,game) of
            (Nothing,_)       -> sendMessage Cancel id1
            (_,Nothing)       -> sendMessage Cancel id1
            (Just (id2,user2),Just g) -> do
                if gamesTurn (entityVal g) /= user1
                  then return ()
                  else do
                         sendMessage (Movement mov) id2
                         let newBoard = if gamesUser1 (entityVal g) == user1
                                          then newMovement mov 1 (gamesMatrix(entityVal g))
                                          else newMovement mov (-1) (gamesMatrix(entityVal g))
                         case checkWinner newBoard of
                           Nothing -> runDBAct pool $ update (entityKey (g)) [GamesMatrix =. newBoard, GamesTurn =. user2]
                           Just x  -> do
                               let msg = if x == 1 
                                           then Winner $ gamesUser1 (entityVal g)
                                           else Winner $ gamesUser2 (entityVal g)
                               sendMessage msg id1
                               sendMessage msg id2
                               deleteGame user1
                               return ()

      NewGame user2 -> do--New Game
          res1 <- getIdentifier user2
          res2 <- isPlaying user2
          case (res1,res2) of
            (Just id2,False) -> do
                 sendMessage (NewGame user1) id2
                 runDBAct pool $ insert $ Games user1 user2 user2 emptyBoard
                 return ()
            (_,_) -> sendMessage Cancel id1

      _ -> return ()
    where
        sendMessage msg id = case id of
                               Web chan -> do
                                             putStrLn $ "Sending on channel: " ++ show msg
                                             atomically $ writeTChan chan msg
                               Dev d    -> do
                                             putStrLn $ "Sending on PushServer: " ++ show msg
                                             res <- sendPush man (getPushNotif $ setMessageValue msg) (HS.singleton d)
                                             if HM.null (failed res)
                                              then return ()
                                              else fail "Problem Communicating with Push Servers"
                                             putStrLn $ "PushResult: " ++ show res
        deleteGame usr     = do
                               runDBAct pool $ deleteBy $ UniqueUser1 usr
                               runDBAct pool $ deleteBy $ UniqueUser2 usr
        getGame usr        = do
                               game1 <- runDBAct pool $ getBy $ UniqueUser1 usr
                               case game1 of
                                 Just _ -> return game1
                                 _      -> runDBAct pool $ getBy $ UniqueUser2 usr
        getIdentifier usr  = do
                               res1 <- runDBAct pool $ getBy $ UniqueUser usr
                               res2 <- return $ HM.lookup usr webUsers
                               case (res1,res2) of
                                 (Just a,_)        -> return $ Just $ Dev (devicesIdentifier (entityVal a))
                                 (_,Just (chan,_)) -> return $ Just $ Web chan
                                 _                 -> return Nothing       
        getOpponentId usr  = do
                               game1 <- runDBAct pool $ getBy $ UniqueUser1 usr
                               game2 <- runDBAct pool $ getBy $ UniqueUser2 usr
                               case (game1,game2) of
                                 (Just g , _) -> do
                                                   let opp = gamesUser2 (entityVal g)
                                                   res <- getIdentifier opp
                                                   return $ res >>= \id -> Just (id,opp)
                                 (_ , Just g) -> do
                                                   let opp = gamesUser1 (entityVal g)
                                                   res <- getIdentifier opp
                                                   return $ res >>= \id -> Just (id,opp)
                                 _            -> return Nothing
        isPlaying usr      = do
                               game1 <- runDBAct pool $ getBy $ UniqueUser1 usr
                               game2 <- runDBAct pool $ getBy $ UniqueUser2 usr
                               case (game1,game2) of
                                 (Nothing,Nothing) -> return False
                                 _                 -> return True
