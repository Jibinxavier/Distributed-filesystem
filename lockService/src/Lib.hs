
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Lib
    ( startApp
    ) where

import           Control.Monad                (when)
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Except   (ExceptT)
import           Control.Monad.Trans.Resource
import           Data.Aeson
import           Data.Aeson.TH
import           Data.Bson.Generic
import qualified Data.ByteString.Lazy         as L
import qualified Data.List                    as DL
import           Data.Maybe
import           Data.Text                    (pack, unpack)
import           Data.Time.Clock              (UTCTime, getCurrentTime)
import           Data.Time.Format             (defaultTimeLocale, formatTime)
import           Database.MongoDB
import           GHC.Generics
import           Network.HTTP.Client          (defaultManagerSettings,
                                               newManager)
import           Network.Wai
import           Network.Wai.Handler.Warp
import           Network.Wai.Logger

import           Servant
import           Network.Socket
import qualified Servant.API                  as SC
import qualified Servant.Client               as SC
import           System.Environment           (getArgs, getProgName, lookupEnv)
import           System.Log.Formatter
import           System.Log.Handler           (setFormatter)
import           System.Log.Handler.Simple
import           System.Log.Handler.Syslog
import           System.Log.Logger
import           Crypto.BCrypt
import           Data.List.Split

import qualified Data.ByteString.Char8        as BS
import qualified FilesystemAPI as FSA  
import           Datatypes 
import           EncryptionAPI
import           FilesystemAPIServer  


 
type API1 =  "lock"                 :> RemoteHost :> ReqBody '[JSON] Message4 :> Post '[JSON] [Bool] 
        :<|> "unlock"               :> RemoteHost :> ReqBody '[JSON] Message3  :> Post '[JSON]  Bool  
        :<|> "islocked"             :> QueryParam "filename" String :> Get '[JSON] Bool 

startApp :: IO ()    -- set up wai logger for service to output apache style logging for rest calls
startApp = FSA.withLogging $ \ aplogger -> do
 
  
  FSA.warnLog "Starting Lock server"
  port <-FSA.lockPortStr
  let settings = setPort  ((read $ port):: Int) $ setLogger aplogger defaultSettings
  runSettings settings app

 
-- of that type is out previously defined REST API) and the second parameter defines the implementation of the REST service.
app :: Application
app = serve api server

api :: Proxy API1
api = Proxy 

server :: Server API1
server = lock 
        :<|> unlock
        :<|> islocked 
  where

    
    -- need to store information about the client 
    -- port number and ip

    lock :: SockAddr -> Message4  -> Handler [Bool] 
    lock addr msg = liftIO $ do
      let (port,file,username) = decryptMessage4 msg
          addrstr = show addr
      FSA.warnLog $ "Trying to lock " ++ file ++ "."
      FSA.warnLog $  show addr

      FSA.withMongoDbConnection $ do
        docs <- find (select ["filename" =: file] "LockService_RECORD") >>= FSA.drainCursor
        let lock =  catMaybes $ DL.map (\ b -> fromBSON b :: Maybe Lock) docs
        case lock of
            [ curLock@(Lock _ True _ queue)] ->liftIO $ do -- locked and adding user to the queue
              let updatedQ = queue ++ [[username,port]]
              FSA.withMongoDbConnection $ upsert (select ["filename" =: file] "LockService_RECORD") $ toBSON $ (curLock{ queue = updatedQ})
              return [True,False]    -- inqueue and lock
            [(Lock _ False _ _ )] -> liftIO $ do
              FSA.withMongoDbConnection $ upsert (select ["filename" =: file] "LockService_RECORD") $ toBSON $ (Lock file True username [])
              return[False,True]    -- not inqueue and lock available
            [] -> liftIO $ do -- there is no file
                FSA.withMongoDbConnection $ upsert (select ["filename" =: file] "LockService_RECORD") $ toBSON $ (Lock file True username [])
                return [False,True]
      
      

    unlock :: SockAddr ->Message3 -> Handler Bool
    unlock addr msg= liftIO $ do
  
      let(file,username) = decryptMessage3 msg  

      --- after unlocking empyty the queue and 
      FSA.withMongoDbConnection $ do -- get the lock and update it
        docs <- find (select ["filename" =: file] "LockService_RECORD") >>= FSA.drainCursor
        let lockStatus = take 1 $ catMaybes $ DL.map (\ b -> fromBSON b :: Maybe Lock) docs
        case lockStatus of
            [(Lock _ True storedUser queue)]  ->liftIO $ do
              case (storedUser==username) of
                (True)-> do
                    FSA.warnLog $ " queue"  ++ show queue
                    let updatedQueue = drop 1 queue
                        (nextuser,clientport) = case (take 1 queue) of  
                          ([[u,port]]) ->(u,port) 
                          otherwise -> ("", "")  
                    
                    
                    FSA.warnLog $ " nextuser  addr"  ++ show nextuser ++ " addr "++ show addr
                    case nextuser of 
                      "" -> liftIO $ do -- no user
                        FSA.warnLog $ "no user"
                        FSA.withMongoDbConnection $ upsert (select ["filename" =: file] "LockService_RECORD") $ toBSON (Lock file False "" [])
                      otherwise -> liftIO $ do
                       
                         ---- inform the client that the lock is available
                        FSA.warnLog $ "Assigning lock to client on port "++ clientport
                        res <- FSA.myrestfullCall (lockAvailable  (LockTransfer file True)) ((read clientport)::Int) FSA.systemHost
                        printResp res "lockAvailable"
                        FSA.withMongoDbConnection $ upsert (select ["filename" =: file] "LockService_RECORD") $ toBSON (Lock file True nextuser updatedQueue)
                    return True  
                (False)-> return False
            
            otherwise -> return False
  
  
    islocked :: Maybe String -> Handler Bool
    islocked (Just key) = liftIO $ do
      
      FSA.warnLog $ "Searching if locked " ++ key
      FSA.withMongoDbConnection $ do
        docs <- find (select ["filename" =: key] "LockService_RECORD") >>= FSA.drainCursor
        let lock =  catMaybes $ DL.map (\ b -> fromBSON b :: Maybe Lock) docs
        case ( lock) of
          [(Lock _ True _ _)] -> return True
          [(Lock _ False _ _)]-> return False
          otherwise -> return False
  
    islocked Nothing = liftIO $ do
        
        FSA.warnLog $ " incorrect format for islocked api: "
        return False
printResp res cmd = do 
  case res of
    Left err -> do
      FSA.warnLog $ "connection error" ++ show err
    Right (replicas) -> FSA.warnLog $ cmd++ " successfull" 