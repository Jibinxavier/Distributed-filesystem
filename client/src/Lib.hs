{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
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
    ( someFunc
    ) where
import           System.IO
import           Control.Monad                 
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Except   (ExceptT)
import           Control.Monad.Trans.Resource
import           Data.Bson.Generic 
import           Distribution.PackageDescription.TH
import           Git.Embed
import           Network.HTTP.Client                (defaultManagerSettings,
                                                     newManager)
import           Options.Applicative
import qualified Servant.API                        as SC
import qualified Servant.Client                     as SC
import           System.Console.ANSI
import           System.Environment
import qualified FilesystemAPI as FSA  
import           FilesystemAPIClient 
import           Data.Time.Clock
import qualified Data.List                    as DL
import           Database.MongoDB       
import           Data.Maybe
import           GHC.Generics
import           Data.Text                    (pack, unpack)
import           Datatypes 
import           EncryptionAPI
import           Helpers        
import           Data.List.Split
import           Data.Char 


   
-- Locking file
---------------------------------------------------
 
doFileLock :: String-> String -> IO ()
doFileLock fpath usern= do
  authInfo <- getAuthClientInfo usern
  case authInfo of 
    (Just (ticket,seshkey) ) -> do 
      let encFpath = myEncryptAES (aesPad seshkey) (fpath)
      let encUname = myEncryptAES (aesPad seshkey) (usern)
      doCall  (lock $ Message3  encFpath encUname ticket) FSA.lockIP FSA.lockPort seshkey

    (Nothing) -> putStrLn $ "Expired token . Sigin in again.  " 
  

doFileUnLock :: String-> String -> IO ()
doFileUnLock fpath usern= do
  authInfo <- getAuthClientInfo usern
  case authInfo of 
    (Just (ticket,seshkey) ) -> do 
      let encFpath = myEncryptAES (aesPad seshkey) (fpath)
      let encUname = myEncryptAES (aesPad seshkey) (usern)
      doCall (unlock  $ Message3 encFpath encUname ticket) FSA.lockIP FSA.lockPort seshkey
    (Nothing) -> putStrLn $ " Expired token  .Sigin in again. " 

doIsLocked :: String  ->  IO ()
doIsLocked fpath  = doCall (islocked $ Just fpath) FSA.lockIP FSA.lockPort $  seshNop
---------------------------------
-- Directory services
---------------------------------

 

  
doListDirs :: String -> IO ()
doListDirs usern=  do 
  authInfo <- getAuthClientInfo usern
  case authInfo of 
    (Just (ticket,seshkey) ) -> do 
      doCall (listdirs $ Just ticket) FSA.dirHost FSA.dirPort seshkey
    (Nothing) -> putStrLn $ "Expired token . Sigin in again.  " 
   --  FSA.dirPort in filesystem api

doLSFileServerContents :: String  -> String -> IO ()
doLSFileServerContents dir usern=docallMsg1WithEnc listfscontents dir usern FSA.dirHost FSA.dirPort 



doFileSearch :: String -> String -> String -> IO ()
doFileSearch dir fname usern = docallMsg3WithEnc  filesearch dir fname usern FSA.dirHost FSA.dirPort
 

-----------------------------
-- Transaction service
-----------------------------
-- client can only do one transaction at a time     
-- Checks the database if there is an transaction running, it would abort and continue with new transaction  
doGetTransId :: String-> IO ()
doGetTransId usern=  do
  res <-  mydoCalMsg1WithEnc getTransId usern ((read $ FSA.transPorStr):: Int)
  case res of
    Nothing ->   putStrLn $ "get file call to fileserver  failed with error: "  
    Just (ResponseData enctrId) -> do 
 

      authInfo <- getAuthClientInfo usern
      case authInfo of 
        (Just (ticket,seshkey) ) -> do
          let trId =  myDecryptAES (aesPad seshkey)  (enctrId)
           
          let key = "client1":: String --- maybe an environment variable in the docker compose
          docs <- withMongoDbConnectionForClient $ find  (select ["key1" =: key] "Transaction_RECORD")  >>= FSA.drainCursor -- getting previous transaction id of the client
          let  clientTrans= take 1 $ catMaybes $ DL.map (\ b -> fromBSON b :: Maybe LocalTransInfo) docs 
          case clientTrans of 
            [LocalTransInfo _  prevId] -> liftIO $ do  -- abort and update
                putStrLn $ "Aborting old transaction and starting new " 
      
                docallMsg1WithEnc abort prevId usern FSA.transIP FSA.transPort
                
              
                withMongoDbConnectionForClient $ upsert (select ["key1" =: key] "Transaction_RECORD") $ toBSON $ LocalTransInfo key trId -- store the transaction id
            [] -> liftIO $ do 
              putStrLn $ "Starting new transaction " ++trId
              withMongoDbConnectionForClient $ upsert (select ["key1" =: key] "Transaction_RECORD") $ toBSON $ LocalTransInfo key trId -- store the transaction id
 
        (Nothing) -> putStrLn $ " Expired token  .Sigin in again. " 
      
 
     
doCommit :: String -> IO ()
doCommit usern = do 
  localTransactionInfo <- getLocalTrId
  case localTransactionInfo of        
    [ LocalTransInfo _ trId] -> liftIO $ do  
      docallMsg1WithEnc commit trId usern FSA.transIP FSA.transPort 
      unlockLockedFiles trId usern
      clearTransaction-- clearing after commiting the transaction
    [] -> putStrLn "No transactions to  commit"

doAbort :: String -> IO ()
doAbort usern  = do 
  localTransactionInfo <- getLocalTrId
  case localTransactionInfo of 
    [LocalTransInfo _ trId] -> liftIO $ do   
      docallMsg1WithEnc abort trId usern FSA.transIP FSA.transPort
      unlockLockedFiles trId usern
      clearTransaction -- clearing after aborting the transaction
    [] -> putStrLn "No transactions to  abort"
-- localfilePath : file path in the client
-- dir           : fileserver name
-- fname         : filename 

doUploadWithTransaction:: String-> String -> String ->  String -> IO ()
doUploadWithTransaction localfilePath  dir fname  usern = do
  localTransactionInfo <- getLocalTrId 
  --  Client will just tell the where they want to store the file 
  -- transaction has to figure out the file info and update directory info  
  let filepath=  dir ++fname
  status <- isFileLocked filepath
  case status of  --- if the file is locked it cannot be added to the transaction
    (False) -> do
      case localTransactionInfo of  -- get local transaction info
        [LocalTransInfo _ trId] -> liftIO $ do     
          contents <- readFile localfilePath
          let filepath = dir++fname
          

          doFileLock filepath usern -- lock the file
          appendToLockedFiles filepath trId -- list of locked files which the client keeps a record of
          res <- mydoCalMsg4WithEnc uploadToShadowDir dir fname trId usern ((read $ FSA.dirServPort):: Int) decryptFInfoTransfer -- uploading info to shadow directory
          --res <- FSA.mydoCall (uploadToShadowDir $  Message3 dir fname trId ) ((read $ fromJust FSA.dirPort):: Int) -- uploading info to shadow directory

          case res of
            Nothing -> putStrLn $ "Upload to transaction failed"  
            Just (a) ->   do 
              case a of 
                ([fileinfotransfer @(FInfoTransfer _ _ fileid _ _ _ )]) -> do
                  let filecontents=FileContents fileid  contents ""
                
                  let transactionContent=TransactionContents trId (TChanges fileinfotransfer filecontents ) ""
                  
                  --- encrypting transaction information before uploading
                  authInfo <- getAuthClientInfo usern
                  case authInfo of 
                    (Just (ticket,seshkey) ) -> do 
                      let msg = encryptTransactionContents transactionContent seshkey ticket
                       
                      doCall (uploadToTransaction $ msg) FSA.transIP FSA.transPort $  seshNop
                    (Nothing) -> putStrLn $ " Expired token  .Sigin in again. " 
                [] -> putStrLn "doUploadWithTransaction: Error getting fileinfo "


          -- call the directory service get info 
          
        [] -> putStrLn "No ongoing transaction"

    (True) -> putStrLn "File is locked"


---------------------------------




doCloseFile:: String -> String  -> String ->  String -> IO ()
doCloseFile localfilePath dir  fname usern = do   -- call to the directory server saying this file has been updated
  let filePath =dir ++ fname
  contents <- readFile localfilePath
  state <- isFileLocked filePath  
  case state of 
    (False) -> do 
         
        res <- mydoCalMsg3WithEnc updateUploadInfo dir fname usern ((read FSA.dirServPort):: Int) decryptFInfoTransfer
        case res of
          Nothing -> putStrLn $ "Upload file failed call failed " 
          (Just a) ->   do 
            case a of 
              [(fileinfotransfer@(FInfoTransfer _ _ fileid h p _ ))] -> do   
                case  p =="none" of
                  (True)->  putStrLn "Upload failed : No fileservers available."
                  (False)-> do
                    doFileLock filePath usern -- lock file before storing
                    putStrLn $ "file locked " 

                    authInfo <- getAuthClientInfo usern
                    case authInfo of 
                      (Just (ticket,seshkey) ) -> do 
                        let msg = encryptFileContents  (FileContents fileid contents "") seshkey ticket -- encrypted message
                        doCall (upload  msg) (Just h) (Just p)  seshkey -- uploading file
                        doFileUnLock filePath usern
                        putStrLn "file unlocked "
                      (Nothing) -> putStrLn $ "Expired token . Sigin in again.  " 



                    

              [] -> putStrLn "Upload file : Error getting fileinfo from directory service"

         
    (True) -> putStrLn "File is locked"

-- client



-- filepath :- id fileserver'
-- dir has to be the name
-- fname    : filename

-- 
displayFile :: String -> IO ()
displayFile filepath = do
  putStrLn $ "Printing contents of the file"
  handle <- openFile filepath ReadMode
  contents <- hGetContents handle
  print contents
  hClose handle   

doWriteFile :: String -> String -> String-> IO ()
doWriteFile dir fname usern = do 
  --- write to file and upload to filserver
  putStrLn $ "" 

doOpenFile :: String -> String -> String-> IO ()
doOpenFile dir fname usern = do 
  -- talk to the directory service to get the file details
  res <- mydoCalMsg3WithEnc filesearch dir fname usern ((read FSA.dirServPort):: Int) decryptFInfoTransfer
  case res of
    Nothing ->  putStrLn $ "download call failed" 
    (Just fileinfo@resp) ->   do 
      case resp of
        [FInfoTransfer filepath dirname fileid ipadr portadr servTm1 ] -> do 
          putStrLn $ portadr ++ "file id "++ fileid

          status <- isDated filepath servTm1  --check with timestamp in the database 
          case status of
            True ->  getFileFromFS  fileinfo usern
            False -> putStrLn "You have most up to date  version" 
        [] -> putStrLn " The file might not be in the fileserver directory" 
        
      displayFile fname
doDownloadFile:: String -> String -> String-> IO ()
doDownloadFile dir fname usern = do -- need to download file 
  
  --res <- FSA.mydoCall (filesearch $  Message3 dir fname "some") ((read FSA.dirServPort):: Int) --- gets file meta from the directory server
  res <- mydoCalMsg3WithEnc filesearch dir fname usern ((read FSA.dirServPort):: Int) decryptFInfoTransfer
  case res of
    Nothing ->  putStrLn $ "download call failed" 
    (Just fileinfo@resp) ->   do 
      case resp of
        [FInfoTransfer filepath dirname fileid ipadr portadr servTm1 ] -> do 
          putStrLn $ portadr ++ "file id "++ fileid

          status <- isDated filepath servTm1  --check with timestamp in the database 
          case status of
            True ->  getFileFromFS  fileinfo usern
            False -> putStrLn "You have most up to date  version" 
        [] -> putStrLn " The file might not be in the directory" 

-- gets the public key of the auth server and encrypts message and sends it over 
doSignup:: String -> String -> IO ()
doSignup userN pass =  do
  resp <- FSA.mydoCall (loadPublicKey) ((read FSA.authPortStr):: Int)
  case resp of
    Left err -> do
      putStrLn $ "failed to get public key... " ++  show err
    Right ((ResponseData a):(ResponseData b):(ResponseData c):rest) -> do
      let authKey = toPublicKey (PubKeyInfo a b c)
      cryptPass <- encryptPass authKey pass
      putStrLn "got the public key!"
      
      doCall (signup $ UserInfo userN cryptPass) FSA.authIP FSA.authPort $  seshNop
      putStrLn "Sent encrypted username and password to authserver"


doLogin:: String -> String-> IO ()
doLogin userN pass  = do
  resp <- FSA.mydoCall (loadPublicKey) ((read FSA.authPortStr):: Int)
  case resp of
    Left err -> do
      putStrLn "failed to get public key..."
    Right ((ResponseData a):(ResponseData b):(ResponseData c):rest) -> do
      let authKey = toPublicKey (PubKeyInfo a b c)
      cryptPass <- encryptPass authKey pass
      putStrLn "got the public key!"
      mydoCall2  (storeClientAuthInfo userN pass) (login $ UserInfo userN cryptPass) ((read FSA.authPortStr):: Int)
      putStrLn "Sending client info (pass and username) to authserver"
      

      
-- | The options handling









-- First we invoke the options on the entry point.
someFunc :: IO ()
someFunc = do 
    menu



menu = do
  contents <- getLine 
  if DL.isPrefixOf "login" contents
    then do
      let cmds =  splitOn " " contents
      --"User name" password"
      doLogin (cmds !! 1) (cmds !! 2)
  else if DL.isPrefixOf  "signup" contents
    then do
      let cmds =  splitOn " " contents
      --"User name" password"
      doSignup  (cmds !! 1) (cmds !! 2)
  else if DL.isPrefixOf  "openfile" contents
    then do
      let cmds =  splitOn " " contents
      -- "remote dir"  "fname" "username"
      doOpenFile  (cmds !! 1) (cmds !! 2) (cmds !! 3)
  else if DL.isPrefixOf  "closefile" contents
    then do
      let cmds =  splitOn " " contents
      -- "local file path" "remote dir" "file name" "user name"
      doCloseFile  (cmds !! 1) (cmds !! 2) (cmds !! 3) (cmds !! 4)
  else if DL.isPrefixOf  "lockfile" contents
    then do
      let cmds =  splitOn " " contents
      -- "remote dir/filename"   "user name"
      doFileLock  (cmds !! 1) (cmds !! 2) 
  else if DL.isPrefixOf  "unlockfile" contents
    then do
      let cmds =  splitOn " " contents
      -- "remote dir/filename"   "user name"
      doFileUnLock  (cmds !! 1) (cmds !! 2) 
  else if DL.isPrefixOf  "listdirs" contents
    then do
      let cmds =  splitOn " " contents
      --   "user name"
      doListDirs  (cmds !! 1) 
  else if DL.isPrefixOf  "lsdircontents" contents
    then do
      let cmds =  splitOn " " contents
      --   "remote dir/filename" "user name"
      doLSFileServerContents  (cmds !! 1)    (cmds !! 2) 
  else if DL.isPrefixOf  "filesearch" contents
    then do
      let cmds =  splitOn " " contents
      --  "remote dir"  "remote dir/filename"   "user name"
      doFileSearch  (cmds !! 1) (cmds !! 2) (cmds !! 3) 

  else if DL.isPrefixOf  "startTrans" contents
    then do
      let cmds =  splitOn " " contents
      --    "user name"
      doGetTransId  (cmds !! 1) 
  else if DL.isPrefixOf  "commit" contents
    then do
      let cmds =  splitOn " " contents
      --    "user name"
      doCommit  (cmds !! 1) 
  else if DL.isPrefixOf  "abort" contents
    then do
      let cmds =  splitOn " " contents
      --    "user name"
      doAbort  (cmds !! 1) 
  else if DL.isPrefixOf  "writeT" contents
    then do
      let cmds =  splitOn " " contents
     -- "local file path" "remote dir" "file name" "user name"
      doUploadWithTransaction  (cmds !! 1) (cmds !! 2) (cmds !! 3) (cmds !! 4)
  else
    putStrLn $"no command specified"
  menu


unlockLockedFiles :: String  -> String -> IO() 
unlockLockedFiles  tid  usern= liftIO $ do
   docs <- withMongoDbConnectionForClient $ find (select ["tid5" =: tid] "LockedFiles_RECORD") >>= FSA.drainCursor
   let  contents= take 1 $ catMaybes $ DL.map (\ b -> fromBSON b :: Maybe LockedFiles) docs 
   case contents of 
    [] -> return ()
    [LockedFiles _ files] -> do -- adding to existing transaction 
      foldM (\ a filepath -> doFileUnLock filepath usern) () files
      withMongoDbConnectionForClient $ delete (select ["tid5" =: tid] "LockedFiles_RECORD")  
