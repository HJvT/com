{-# OPTIONS -XCPP -#include "comPrim.h" #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  System.Win32.Com.Exception
-- Copyright   :  (c) 2009, Sigbjorn Finne
-- License     :  BSD-style (see the file libraries/base/LICENSE)
-- 
-- Maintainer  :  sof@forkIO.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Representing and working with COM's 'exception model' (@HRESULT@s) in Haskell.
-- Failures in COM method calls are mapped into 'Control.Exception' Haskell exceptions,
-- providing convenient handlers to catch and throw these.
-- 
-----------------------------------------------------------------------------
module System.Win32.Com.Exception where

import System.Win32.Com.HDirect.HDirect hiding ( readFloat )
import System.Win32.Com.Base
import Data.Int
import Data.Word
import Data.Bits
import Data.Dynamic
import Data.Maybe ( isJust, fromMaybe )
import Numeric ( showHex )
import System.IO.Error ( ioeGetErrorString )

#if BASE == 3
import GHC.IOBase
import Control.Exception

-- | @act `catchComException` (ex -> hdlr ex)@ performs the 
-- IO action @act@, but catches any IO or COM exceptions @ex@,
-- passing them to the handler @hdlr@. 
catchComException :: IO a -> (Com_Exception -> IO a) -> IO a
catchComException act hdlr = 
   Control.Exception.catch act
      (\ ex -> 
        case ex of
	  DynException d -> 
	    case fromDynamic d of
	      Just ce -> hdlr (Right ce)
	      _       -> throwIO ex
	  IOException ioe -> hdlr (Left ioe)
	  _ -> throwIO ex)

catch_ce_ :: IO a -> (Maybe ComException -> IO a) -> IO a
catch_ce_ act hdlr = 
   catchComException
      act 
      (\ e ->
        case e of
	  Left  ioe -> hdlr Nothing
	  Right ce ->  hdlr (Just ce))

#else
import Control.Exception

-- | @act `catchComException` (ex -> hdlr ex)@ performs the 
-- IO action @act@, but catches any IO or COM exceptions @ex@,
-- passing them to the handler @hdlr@. 
catchComException :: IO a -> (Com_Exception -> IO a) -> IO a
catchComException act hdlr = 
  Control.Exception.catch act
     (\ e -> 
        case fromException e of
	  Just ioe -> hdlr (Left ioe)
	  _ -> case fromException e of
	        Just d -> hdlr (Right d)
		_      -> throwIO e)

catch_ce_ :: IO a -> (Maybe ComException -> IO a) -> IO a
catch_ce_ act hdlr = 
   catchComException
      act 
      (\ e ->
        case e of
	  Left  ioe -> hdlr Nothing
	  Right ce ->  hdlr (Just ce))
#endif

-- | @Com_Exception@ is either an 'IOException' or 'ComException';
-- no attempt is made to embed one inside the other.
type Com_Exception = Either IOException ComException

-- | @throwIOComException ex@ raises/throws the exception @ex@;
-- @ex@ is either an 'IOException' or a 'ComException'.
throwIOComException :: Com_Exception -> IO a
throwIOComException (Left e) = ioError e
throwIOComException (Right ce) = throwComException ce

-- | @check2HR hr@ triggers a COM exception if the HRESULT
-- @hr@ represent an error condition. The current /last error/
-- value embedded in the exception gives more information about
-- cause.
check2HR :: HRESULT -> IO ()
check2HR hr
      | succeeded hr = return ()
      | otherwise    = do
	  dw <- getLastError
	  coFailHR (word32ToInt32 dw)

-- | @checkBool mbZero@ raises a COM exception if @mbZero@ is equal
-- to...zero. The /last error/ is embedded inside the exception.
checkBool :: Int32 -> IO ()
checkBool flg
      | flg /=0      = return ()
      | otherwise    = do
	  dw <- getLastError
	  coFailHR (word32ToInt32 dw)

-- | @returnHR act@ runs the IO action @act@, catching any
-- COM exceptions. Success or failure is then mapped back into
-- the corresponding HRESULT. In the case of success, 's_OK'.
returnHR :: IO () -> IO HRESULT
returnHR act = 
   catch_ce_
     (act >> return s_OK)
     (\ mb_hr -> return (maybe failure toHR mb_hr))
 where
  toHR ComException{comException=(ComError hr)} = hr
   -- better return codes could easily be imagined..
  failure = e_FAIL


-- | @isCoError e@ returns @True@ for COM exceptions; @False@
-- for IO exception values.
isCoError        :: Com_Exception -> Bool
isCoError Right{} = True
isCoError Left{}  = False

-- | @coGetException ei@ picks out the COM exception @ei@, if one.
coGetException   :: Com_Exception -> Maybe ComException
coGetException (Right ce) = Just ce
coGetException _ = Nothing

-- | @coGetException ei@ picks out the COM HRESULT from the exception, if any.
coGetErrorHR     :: Com_Exception -> Maybe HRESULT
coGetErrorHR Left{} = Nothing
coGetErrorHR (Right ce) = Just (case comException ce of (ComError hr) -> hr)

-- | @coGetException ei@ returns a user-friendlier representation of the @ei@ exception.
coGetErrorString :: Com_Exception -> String
coGetErrorString (Left ioe) = ioeGetErrorString ioe
coGetErrorString (Right ce) = 
   comExceptionMsg ce ++ 
   showParen True (showHex (int32ToWord32 (comExceptionHR ce))) ""

printComError :: Com_Exception -> IO ()
printComError ce = putStrLn (coGetErrorString ce)

-- | An alias to 'coGetErrorString'.
hresultToString :: HRESULT -> IO String
hresultToString = stringFromHR

coAssert :: Bool -> String -> IO ()
coAssert True msg    = return ()
coAssert False msg   = coFail msg

coOnFail :: IO a -> String -> IO a
coOnFail io msg      = catchComException io
    (\ e -> 
       case e of
         Left  ioe -> coFail (msg ++ ": " ++ ioeGetErrorString ioe)
	 Right ce  -> coFail (msg ++ ": " ++ comExceptionMsg ce))

-- | @coFail msg@ raised the @E_FAIL@ COM exception along with
-- the descriptive string @msg@.
coFail :: String -> IO a
coFail = coFailWithHR e_FAIL 

-- | @s_OK@ and @s_FALSE@ are the boolean values encoded as 'HRESULT's.
s_FALSE, s_OK :: HRESULT
s_OK = 0
s_FALSE = 1

nOERROR :: HRESULT
nOERROR = 0 

nO_ERROR :: HRESULT
nO_ERROR = 0

sEVERITY_ERROR :: Int32
sEVERITY_ERROR = 1 
sEVERITY_SUCCESS :: Int32
sEVERITY_SUCCESS = 0 

succeeded :: HRESULT -> Bool
succeeded hr = hr >=0

winErrorToHR :: Int32 -> HRESULT
winErrorToHR 0 = 0
winErrorToHR x = (fACILITY_WIN32 `shiftL` 16) .|. (bit 31) .|. (x .&. 0xffff)

hRESULT_CODE :: HRESULT -> Int32
hRESULT_CODE hr = hr .&. (fromIntegral 0xffff)

hRESULT_FACILITY :: HRESULT -> Int32
hRESULT_FACILITY hr = (hr `shiftR` 16) .&. 0x1fff

hRESULT_SEVERITY :: HRESULT -> Int32
hRESULT_SEVERITY hr = (hr `shiftR` 31) .&. 0x1

mkHRESULT :: Int32 -> Int32 -> Int32 -> HRESULT
mkHRESULT sev fac code = 
  word32ToInt32 (
      ((int32ToWord32 sev) `shiftL` 31) .|. 
      ((int32ToWord32 fac) `shiftL` 16) .|.
      (int32ToWord32 code)
     )


cAT_E_CATIDNOEXIST :: HRESULT
cAT_E_CATIDNOEXIST = word32ToInt32 (0x80040160 ::Word32)
cAT_E_FIRST :: HRESULT
cAT_E_FIRST = word32ToInt32 (0x80040160 ::Word32)
cAT_E_LAST :: HRESULT
cAT_E_LAST = word32ToInt32 (0x80040161 ::Word32)
cAT_E_NODESCRIPTION :: HRESULT
cAT_E_NODESCRIPTION = word32ToInt32 (0x80040161 ::Word32)
cLASS_E_CLASSNOTAVAILABLE :: HRESULT
cLASS_E_CLASSNOTAVAILABLE = word32ToInt32 (0x80040111 ::Word32)
cLASS_E_NOAGGREGATION :: HRESULT
cLASS_E_NOAGGREGATION = word32ToInt32 (0x80040110 ::Word32)
cLASS_E_NOTLICENSED :: HRESULT
cLASS_E_NOTLICENSED = word32ToInt32 (0x80040112 ::Word32)
cO_E_ACCESSCHECKFAILED :: HRESULT
cO_E_ACCESSCHECKFAILED = word32ToInt32 (0x80040207 ::Word32)
cO_E_ACESINWRONGORDER :: HRESULT
cO_E_ACESINWRONGORDER = word32ToInt32 (0x80040217 ::Word32)
cO_E_ACNOTINITIALIZED :: HRESULT
cO_E_ACNOTINITIALIZED = word32ToInt32 (0x8004021B ::Word32)
cO_E_ALREADYINITIALIZED :: HRESULT
cO_E_ALREADYINITIALIZED = word32ToInt32 (0x800401F1 ::Word32)
cO_E_APPDIDNTREG :: HRESULT
cO_E_APPDIDNTREG = word32ToInt32 (0x800401FE ::Word32)
cO_E_APPNOTFOUND :: HRESULT
cO_E_APPNOTFOUND = word32ToInt32 (0x800401F5 ::Word32)
cO_E_APPSINGLEUSE :: HRESULT
cO_E_APPSINGLEUSE = word32ToInt32 (0x800401F6 ::Word32)
cO_E_BAD_PATH :: HRESULT
cO_E_BAD_PATH = word32ToInt32 (0x80080004 ::Word32)
cO_E_BAD_SERVER_NAME :: HRESULT
cO_E_BAD_SERVER_NAME = word32ToInt32 (0x80004014 ::Word32)
cO_E_CANTDETERMINECLASS :: HRESULT
cO_E_CANTDETERMINECLASS = word32ToInt32 (0x800401F2 ::Word32)
cO_E_CANT_REMOTE :: HRESULT
cO_E_CANT_REMOTE = word32ToInt32 (0x80004013 ::Word32)
cO_E_CLASSSTRING :: HRESULT
cO_E_CLASSSTRING = word32ToInt32 (0x800401F3 ::Word32)
cO_E_CLASS_CREATE_FAILED :: HRESULT
cO_E_CLASS_CREATE_FAILED = word32ToInt32 (0x80080001 ::Word32)
cO_E_CLSREG_INCONSISTENT :: HRESULT
cO_E_CLSREG_INCONSISTENT = word32ToInt32 (0x8000401F ::Word32)
cO_E_CONVERSIONFAILED :: HRESULT
cO_E_CONVERSIONFAILED = word32ToInt32 (0x8004020B ::Word32)
cO_E_CREATEPROCESS_FAILURE :: HRESULT
cO_E_CREATEPROCESS_FAILURE = word32ToInt32 (0x80004018 ::Word32)
cO_E_DECODEFAILED :: HRESULT
cO_E_DECODEFAILED = word32ToInt32 (0x8004021A ::Word32)
cO_E_DLLNOTFOUND :: HRESULT
cO_E_DLLNOTFOUND = word32ToInt32 (0x800401F8 ::Word32)
cO_E_ERRORINAPP :: HRESULT
cO_E_ERRORINAPP = word32ToInt32 (0x800401F7 ::Word32)
cO_E_ERRORINDLL :: HRESULT
cO_E_ERRORINDLL = word32ToInt32 (0x800401F9 ::Word32)
cO_E_EXCEEDSYSACLLIMIT :: HRESULT
cO_E_EXCEEDSYSACLLIMIT = word32ToInt32 (0x80040216 ::Word32)
cO_E_FAILEDTOCLOSEHANDLE :: HRESULT
cO_E_FAILEDTOCLOSEHANDLE = word32ToInt32 (0x80040215 ::Word32)
cO_E_FAILEDTOCREATEFILE :: HRESULT
cO_E_FAILEDTOCREATEFILE = word32ToInt32 (0x80040214 ::Word32)
cO_E_FAILEDTOGENUUID :: HRESULT
cO_E_FAILEDTOGENUUID = word32ToInt32 (0x80040213 ::Word32)
cO_E_FAILEDTOGETSECCTX :: HRESULT
cO_E_FAILEDTOGETSECCTX = word32ToInt32 (0x80040201 ::Word32)
cO_E_FAILEDTOGETTOKENINFO :: HRESULT
cO_E_FAILEDTOGETTOKENINFO = word32ToInt32 (0x80040203 ::Word32)
cO_E_FAILEDTOGETWINDIR :: HRESULT
cO_E_FAILEDTOGETWINDIR = word32ToInt32 (0x80040211 ::Word32)
cO_E_FAILEDTOIMPERSONATE :: HRESULT
cO_E_FAILEDTOIMPERSONATE = word32ToInt32 (0x80040200 ::Word32)
cO_E_FAILEDTOOPENPROCESSTOKEN :: HRESULT
cO_E_FAILEDTOOPENPROCESSTOKEN = word32ToInt32 (0x80040219 ::Word32)
cO_E_FAILEDTOOPENTHREADTOKEN :: HRESULT
cO_E_FAILEDTOOPENTHREADTOKEN = word32ToInt32 (0x80040202 ::Word32)
cO_E_FAILEDTOQUERYCLIENTBLANKET :: HRESULT
cO_E_FAILEDTOQUERYCLIENTBLANKET = word32ToInt32 (0x80040205 ::Word32)
cO_E_FAILEDTOSETDACL :: HRESULT
cO_E_FAILEDTOSETDACL = word32ToInt32 (0x80040206 ::Word32)
cO_E_FIRST :: HRESULT
cO_E_FIRST = word32ToInt32 (0x800401F0 ::Word32)
cO_E_IIDREG_INCONSISTENT :: HRESULT
cO_E_IIDREG_INCONSISTENT = word32ToInt32 (0x80004020 ::Word32)
cO_E_IIDSTRING :: HRESULT
cO_E_IIDSTRING = word32ToInt32 (0x800401F4 ::Word32)
cO_E_INCOMPATIBLESTREAMVERSION :: HRESULT
cO_E_INCOMPATIBLESTREAMVERSION = word32ToInt32 (0x80040218 ::Word32)
cO_E_INIT_CLASS_CACHE :: HRESULT
cO_E_INIT_CLASS_CACHE = word32ToInt32 (0x80004009 ::Word32)
cO_E_INIT_MEMORY_ALLOCATOR :: HRESULT
cO_E_INIT_MEMORY_ALLOCATOR = word32ToInt32 (0x80004008 ::Word32)
cO_E_INIT_ONLY_SINGLE_THREADED :: HRESULT
cO_E_INIT_ONLY_SINGLE_THREADED = word32ToInt32 (0x80004012 ::Word32)
cO_E_INIT_RPC_CHANNEL :: HRESULT
cO_E_INIT_RPC_CHANNEL = word32ToInt32 (0x8000400A ::Word32)
cO_E_INIT_SCM_EXEC_FAILURE :: HRESULT
cO_E_INIT_SCM_EXEC_FAILURE = word32ToInt32 (0x80004011 ::Word32)
cO_E_INIT_SCM_FILE_MAPPING_EXISTS :: HRESULT
cO_E_INIT_SCM_FILE_MAPPING_EXISTS = word32ToInt32 (0x8000400F ::Word32)
cO_E_INIT_SCM_MAP_VIEW_OF_FILE :: HRESULT
cO_E_INIT_SCM_MAP_VIEW_OF_FILE = word32ToInt32 (0x80004010 ::Word32)
cO_E_INIT_SCM_MUTEX_EXISTS :: HRESULT
cO_E_INIT_SCM_MUTEX_EXISTS = word32ToInt32 (0x8000400E ::Word32)
cO_E_INIT_SHARED_ALLOCATOR :: HRESULT
cO_E_INIT_SHARED_ALLOCATOR = word32ToInt32 (0x80004007 ::Word32)
cO_E_INIT_TLS :: HRESULT
cO_E_INIT_TLS = word32ToInt32 (0x80004006 ::Word32)
cO_E_INIT_TLS_CHANNEL_CONTROL :: HRESULT
cO_E_INIT_TLS_CHANNEL_CONTROL = word32ToInt32 (0x8000400C ::Word32)
cO_E_INIT_TLS_SET_CHANNEL_CONTROL :: HRESULT
cO_E_INIT_TLS_SET_CHANNEL_CONTROL = word32ToInt32 (0x8000400B ::Word32)
cO_E_INIT_UNACCEPTED_USER_ALLOCATOR :: HRESULT
cO_E_INIT_UNACCEPTED_USER_ALLOCATOR = word32ToInt32 (0x8000400D ::Word32)
cO_E_INVALIDSID :: HRESULT
cO_E_INVALIDSID = word32ToInt32 (0x8004020A ::Word32)
cO_E_LAST :: HRESULT
cO_E_LAST = word32ToInt32 (0x800401FF ::Word32)
cO_E_LAUNCH_PERMSSION_DENIED :: HRESULT
cO_E_LAUNCH_PERMSSION_DENIED = word32ToInt32 (0x8000401B ::Word32)
cO_E_LOOKUPACCNAMEFAILED :: HRESULT
cO_E_LOOKUPACCNAMEFAILED = word32ToInt32 (0x8004020F ::Word32)
cO_E_LOOKUPACCSIDFAILED :: HRESULT
cO_E_LOOKUPACCSIDFAILED = word32ToInt32 (0x8004020D ::Word32)
cO_E_MSI_ERROR :: HRESULT
cO_E_MSI_ERROR = word32ToInt32 (0x80004023 ::Word32)
cO_E_NETACCESSAPIFAILED :: HRESULT
cO_E_NETACCESSAPIFAILED = word32ToInt32 (0x80040208 ::Word32)
cO_E_NOMATCHINGNAMEFOUND :: HRESULT
cO_E_NOMATCHINGNAMEFOUND = word32ToInt32 (0x8004020E ::Word32)
cO_E_NOMATCHINGSIDFOUND :: HRESULT
cO_E_NOMATCHINGSIDFOUND = word32ToInt32 (0x8004020C ::Word32)
cO_E_NOTINITIALIZED :: HRESULT
cO_E_NOTINITIALIZED = word32ToInt32 (0x800401F0 ::Word32)
cO_E_NOT_SUPPORTED :: HRESULT
cO_E_NOT_SUPPORTED = word32ToInt32 (0x80004021 ::Word32)
cO_E_OBJISREG :: HRESULT
cO_E_OBJISREG = word32ToInt32 (0x800401FC ::Word32)
cO_E_OBJNOTCONNECTED :: HRESULT
cO_E_OBJNOTCONNECTED = word32ToInt32 (0x800401FD ::Word32)
cO_E_OBJNOTREG :: HRESULT
cO_E_OBJNOTREG = word32ToInt32 (0x800401FB ::Word32)
cO_E_OBJSRV_RPC_FAILURE :: HRESULT
cO_E_OBJSRV_RPC_FAILURE = word32ToInt32 (0x80080006 ::Word32)
cO_E_OLE1DDE_DISABLED :: HRESULT
cO_E_OLE1DDE_DISABLED = word32ToInt32 (0x80004016 ::Word32)
cO_E_PATHTOOLONG :: HRESULT
cO_E_PATHTOOLONG = word32ToInt32 (0x80040212 ::Word32)
cO_E_RELEASED :: HRESULT
cO_E_RELEASED = word32ToInt32 (0x800401FF ::Word32)
cO_E_RELOAD_DLL :: HRESULT
cO_E_RELOAD_DLL = word32ToInt32 (0x80004022 ::Word32)
cO_E_REMOTE_COMMUNICATION_FAILURE :: HRESULT
cO_E_REMOTE_COMMUNICATION_FAILURE = word32ToInt32 (0x8000401D ::Word32)
cO_E_RUNAS_CREATEPROCESS_FAILURE :: HRESULT
cO_E_RUNAS_CREATEPROCESS_FAILURE = word32ToInt32 (0x80004019 ::Word32)
cO_E_RUNAS_LOGON_FAILURE :: HRESULT
cO_E_RUNAS_LOGON_FAILURE = word32ToInt32 (0x8000401A ::Word32)
cO_E_RUNAS_SYNTAX :: HRESULT
cO_E_RUNAS_SYNTAX = word32ToInt32 (0x80004017 ::Word32)
cO_E_SCM_ERROR :: HRESULT
cO_E_SCM_ERROR = word32ToInt32 (0x80080002 ::Word32)
cO_E_SCM_RPC_FAILURE :: HRESULT
cO_E_SCM_RPC_FAILURE = word32ToInt32 (0x80080003 ::Word32)
cO_E_SERVER_EXEC_FAILURE :: HRESULT
cO_E_SERVER_EXEC_FAILURE = word32ToInt32 (0x80080005 ::Word32)
cO_E_SERVER_START_TIMEOUT :: HRESULT
cO_E_SERVER_START_TIMEOUT = word32ToInt32 (0x8000401E ::Word32)
cO_E_SERVER_STOPPING :: HRESULT
cO_E_SERVER_STOPPING = word32ToInt32 (0x80080008 ::Word32)
cO_E_SETSERLHNDLFAILED :: HRESULT
cO_E_SETSERLHNDLFAILED = word32ToInt32 (0x80040210 ::Word32)
cO_E_START_SERVICE_FAILURE :: HRESULT
cO_E_START_SERVICE_FAILURE = word32ToInt32 (0x8000401C ::Word32)
cO_E_TRUSTEEDOESNTMATCHCLIENT :: HRESULT
cO_E_TRUSTEEDOESNTMATCHCLIENT = word32ToInt32 (0x80040204 ::Word32)
cO_E_WRONGOSFORAPP :: HRESULT
cO_E_WRONGOSFORAPP = word32ToInt32 (0x800401FA ::Word32)
cO_E_WRONGTRUSTEENAMESYNTAX :: HRESULT
cO_E_WRONGTRUSTEENAMESYNTAX = word32ToInt32 (0x80040209 ::Word32)
cO_E_WRONG_SERVER_IDENTITY :: HRESULT
cO_E_WRONG_SERVER_IDENTITY = word32ToInt32 (0x80004015 ::Word32)
cO_S_FIRST :: HRESULT
cO_S_FIRST = word32ToInt32 (0x000401F0 ::Word32)
cO_S_LAST :: HRESULT
cO_S_LAST = word32ToInt32 (0x000401FF ::Word32)
cO_S_NOTALLINTERFACES :: HRESULT
cO_S_NOTALLINTERFACES = word32ToInt32 (0x00080012 ::Word32)
dISP_E_ARRAYISLOCKED :: HRESULT
dISP_E_ARRAYISLOCKED = word32ToInt32 (0x8002000D ::Word32)
dISP_E_BADCALLEE :: HRESULT
dISP_E_BADCALLEE = word32ToInt32 (0x80020010 ::Word32)
dISP_E_BADINDEX :: HRESULT
dISP_E_BADINDEX = word32ToInt32 (0x8002000B ::Word32)
dISP_E_BADPARAMCOUNT :: HRESULT
dISP_E_BADPARAMCOUNT = word32ToInt32 (0x8002000E ::Word32)
dISP_E_BADVARTYPE :: HRESULT
dISP_E_BADVARTYPE = word32ToInt32 (0x80020008 ::Word32)
dISP_E_DIVBYZERO :: HRESULT
dISP_E_DIVBYZERO = word32ToInt32 (0x80020012 ::Word32)
dISP_E_EXCEPTION :: HRESULT
dISP_E_EXCEPTION = word32ToInt32 (0x80020009 ::Word32)
dISP_E_MEMBERNOTFOUND :: HRESULT
dISP_E_MEMBERNOTFOUND = word32ToInt32 (0x80020003 ::Word32)
dISP_E_NONAMEDARGS :: HRESULT
dISP_E_NONAMEDARGS = word32ToInt32 (0x80020007 ::Word32)
dISP_E_NOTACOLLECTION :: HRESULT
dISP_E_NOTACOLLECTION = word32ToInt32 (0x80020011 ::Word32)
dISP_E_OVERFLOW :: HRESULT
dISP_E_OVERFLOW = word32ToInt32 (0x8002000A ::Word32)
dISP_E_PARAMNOTFOUND :: HRESULT
dISP_E_PARAMNOTFOUND = word32ToInt32 (0x80020004 ::Word32)
dISP_E_PARAMNOTOPTIONAL :: HRESULT
dISP_E_PARAMNOTOPTIONAL = word32ToInt32 (0x8002000F ::Word32)
dISP_E_TYPEMISMATCH :: HRESULT
dISP_E_TYPEMISMATCH = word32ToInt32 (0x80020005 ::Word32)
dISP_E_UNKNOWNINTERFACE :: HRESULT
dISP_E_UNKNOWNINTERFACE = word32ToInt32 (0x80020001 ::Word32)
dISP_E_UNKNOWNLCID :: HRESULT
dISP_E_UNKNOWNLCID = word32ToInt32 (0x8002000C ::Word32)
dISP_E_UNKNOWNNAME :: HRESULT
dISP_E_UNKNOWNNAME = word32ToInt32 (0x80020006 ::Word32)
dV_E_CLIPFORMAT :: HRESULT
dV_E_CLIPFORMAT = word32ToInt32 (0x8004006A ::Word32)
dV_E_DVASPECT :: HRESULT
dV_E_DVASPECT = word32ToInt32 (0x8004006B ::Word32)
dV_E_DVTARGETDEVICE :: HRESULT
dV_E_DVTARGETDEVICE = word32ToInt32 (0x80040065 ::Word32)
dV_E_DVTARGETDEVICE_SIZE :: HRESULT
dV_E_DVTARGETDEVICE_SIZE = word32ToInt32 (0x8004006C ::Word32)
dV_E_FORMATETC :: HRESULT
dV_E_FORMATETC = word32ToInt32 (0x80040064 ::Word32)
dV_E_LINDEX :: HRESULT
dV_E_LINDEX = word32ToInt32 (0x80040068 ::Word32)
dV_E_NOIVIEWOBJECT :: HRESULT
dV_E_NOIVIEWOBJECT = word32ToInt32 (0x8004006D ::Word32)
dV_E_STATDATA :: HRESULT
dV_E_STATDATA = word32ToInt32 (0x80040067 ::Word32)
dV_E_STGMEDIUM :: HRESULT
dV_E_STGMEDIUM = word32ToInt32 (0x80040066 ::Word32)
dV_E_TYMED :: HRESULT
dV_E_TYMED = word32ToInt32 (0x80040069 ::Word32)
e_ABORT :: HRESULT
e_ABORT = word32ToInt32 (0x80004004 ::Word32)
e_ACCESSDENIED :: HRESULT
e_ACCESSDENIED = word32ToInt32 (0x80070005 ::Word32)
e_FAIL :: HRESULT
e_FAIL = word32ToInt32 (0x80004005 ::Word32)
e_HANDLE :: HRESULT
e_HANDLE = word32ToInt32 (0x80070006 ::Word32)
e_INVALIDARG :: HRESULT
e_INVALIDARG = word32ToInt32 (0x80070057 ::Word32)
e_NOINTERFACE :: HRESULT
e_NOINTERFACE = word32ToInt32 (0x80004002 ::Word32)
e_NOTIMPL :: HRESULT
e_NOTIMPL = word32ToInt32 (0x80004001 ::Word32)
e_OUTOFMEMORY :: HRESULT
e_OUTOFMEMORY = word32ToInt32 (0x8007000E ::Word32)
e_PENDING :: HRESULT
e_PENDING = word32ToInt32 (0x8000000A ::Word32)
e_POINTER :: HRESULT
e_POINTER = word32ToInt32 (0x80004003 ::Word32)
e_UNEXPECTED :: HRESULT
e_UNEXPECTED = word32ToInt32 (0x8000FFFF ::Word32)

fACILITY_CERT :: HRESULT
fACILITY_CERT = 11 
fACILITY_CONTROL :: HRESULT
fACILITY_CONTROL = 10 
fACILITY_DISPATCH :: HRESULT
fACILITY_DISPATCH = 2 
fACILITY_INTERNET :: HRESULT
fACILITY_INTERNET = 12 
fACILITY_ITF :: HRESULT
fACILITY_ITF = 4 
fACILITY_MEDIASERVER :: HRESULT
fACILITY_MEDIASERVER = 13 
fACILITY_MSMQ :: HRESULT
fACILITY_MSMQ = 14 
fACILITY_NT_BIT :: HRESULT
fACILITY_NT_BIT = word32ToInt32 (0x10000000 ::Word32)
fACILITY_NULL :: HRESULT
fACILITY_NULL = 0 
fACILITY_RPC :: HRESULT
fACILITY_RPC = 1 
fACILITY_SETUPAPI :: HRESULT
fACILITY_SETUPAPI = 15 
fACILITY_SSPI :: HRESULT
fACILITY_SSPI = 9 
fACILITY_STORAGE :: HRESULT
fACILITY_STORAGE = 3 
fACILITY_WIN32 :: HRESULT
fACILITY_WIN32 = 7 
fACILITY_WINDOWS :: HRESULT
fACILITY_WINDOWS = 8 

iNPLACE_E_FIRST :: HRESULT
iNPLACE_E_FIRST = word32ToInt32 (0x800401A0 ::Word32)
iNPLACE_E_LAST :: HRESULT
iNPLACE_E_LAST = word32ToInt32 (0x800401AF ::Word32)
iNPLACE_E_NOTOOLSPACE :: HRESULT
iNPLACE_E_NOTOOLSPACE = word32ToInt32 (0x800401A1 ::Word32)
iNPLACE_E_NOTUNDOABLE :: HRESULT
iNPLACE_E_NOTUNDOABLE = word32ToInt32 (0x800401A0 ::Word32)
iNPLACE_S_FIRST :: HRESULT
iNPLACE_S_FIRST = word32ToInt32 (0x000401A0 ::Word32)
iNPLACE_S_LAST :: HRESULT
iNPLACE_S_LAST = word32ToInt32 (0x000401AF ::Word32)
iNPLACE_S_TRUNCATED :: HRESULT
iNPLACE_S_TRUNCATED = word32ToInt32 (0x000401A0 ::Word32)

mARSHAL_E_FIRST :: HRESULT
mARSHAL_E_FIRST = word32ToInt32 (0x80040120 ::Word32)
mARSHAL_E_LAST :: HRESULT
mARSHAL_E_LAST = word32ToInt32 (0x8004012F ::Word32)
mARSHAL_S_FIRST :: HRESULT
mARSHAL_S_FIRST = word32ToInt32 (0x00040120 ::Word32)
mARSHAL_S_LAST :: HRESULT
mARSHAL_S_LAST = word32ToInt32 (0x0004012F ::Word32)

mEM_E_INVALID_LINK :: HRESULT
mEM_E_INVALID_LINK = word32ToInt32 (0x80080010 ::Word32)
mEM_E_INVALID_ROOT :: HRESULT
mEM_E_INVALID_ROOT = word32ToInt32 (0x80080009 ::Word32)
mEM_E_INVALID_SIZE :: HRESULT
mEM_E_INVALID_SIZE = word32ToInt32 (0x80080011 ::Word32)

mK_E_CANTOPENFILE :: HRESULT
mK_E_CANTOPENFILE = word32ToInt32 (0x800401EA ::Word32)
mK_E_CONNECTMANUALLY :: HRESULT
mK_E_CONNECTMANUALLY = word32ToInt32 (0x800401E0 ::Word32)
mK_E_ENUMERATION_FAILED :: HRESULT
mK_E_ENUMERATION_FAILED = word32ToInt32 (0x800401EF ::Word32)
mK_E_EXCEEDEDDEADLINE :: HRESULT
mK_E_EXCEEDEDDEADLINE = word32ToInt32 (0x800401E1 ::Word32)
mK_E_FIRST :: HRESULT
mK_E_FIRST = word32ToInt32 (0x800401E0 ::Word32)
mK_E_INTERMEDIATEINTERFACENOTSUPPORTED :: HRESULT
mK_E_INTERMEDIATEINTERFACENOTSUPPORTED = word32ToInt32 (0x800401E7 ::Word32)
mK_E_INVALIDEXTENSION :: HRESULT
mK_E_INVALIDEXTENSION = word32ToInt32 (0x800401E6 ::Word32)
mK_E_LAST :: HRESULT
mK_E_LAST = word32ToInt32 (0x800401EF ::Word32)
mK_E_MUSTBOTHERUSER :: HRESULT
mK_E_MUSTBOTHERUSER = word32ToInt32 (0x800401EB ::Word32)
mK_E_NEEDGENERIC :: HRESULT
mK_E_NEEDGENERIC = word32ToInt32 (0x800401E2 ::Word32)
mK_E_NOINVERSE :: HRESULT
mK_E_NOINVERSE = word32ToInt32 (0x800401EC ::Word32)
mK_E_NOOBJECT :: HRESULT
mK_E_NOOBJECT = word32ToInt32 (0x800401E5 ::Word32)
mK_E_NOPREFIX :: HRESULT
mK_E_NOPREFIX = word32ToInt32 (0x800401EE ::Word32)
mK_E_NOSTORAGE :: HRESULT
mK_E_NOSTORAGE = word32ToInt32 (0x800401ED ::Word32)
mK_E_NOTBINDABLE :: HRESULT
mK_E_NOTBINDABLE = word32ToInt32 (0x800401E8 ::Word32)
mK_E_NOTBOUND :: HRESULT
mK_E_NOTBOUND = word32ToInt32 (0x800401E9 ::Word32)
mK_E_NO_NORMALIZED :: HRESULT
mK_E_NO_NORMALIZED = word32ToInt32 (0x80080007 ::Word32)
mK_E_SYNTAX :: HRESULT
mK_E_SYNTAX = word32ToInt32 (0x800401E4 ::Word32)
mK_E_UNAVAILABLE :: HRESULT
mK_E_UNAVAILABLE = word32ToInt32 (0x800401E3 ::Word32)
mK_S_FIRST :: HRESULT
mK_S_FIRST = word32ToInt32 (0x000401E0 ::Word32)
mK_S_HIM :: HRESULT
mK_S_HIM = word32ToInt32 (0x000401E5 ::Word32)
mK_S_LAST :: HRESULT
mK_S_LAST = word32ToInt32 (0x000401EF ::Word32)
mK_S_ME :: HRESULT
mK_S_ME = word32ToInt32 (0x000401E4 ::Word32)
mK_S_MONIKERALREADYREGISTERED :: HRESULT
mK_S_MONIKERALREADYREGISTERED = word32ToInt32 (0x000401E7 ::Word32)
mK_S_REDUCED_TO_SELF :: HRESULT
mK_S_REDUCED_TO_SELF = word32ToInt32 (0x000401E2 ::Word32)
mK_S_US :: HRESULT
mK_S_US = word32ToInt32 (0x000401E6 ::Word32)

oLEOBJ_E_FIRST :: HRESULT
oLEOBJ_E_FIRST = word32ToInt32 (0x80040180 ::Word32)
oLEOBJ_E_INVALIDVERB :: HRESULT
oLEOBJ_E_INVALIDVERB = word32ToInt32 (0x80040181 ::Word32)
oLEOBJ_E_LAST :: HRESULT
oLEOBJ_E_LAST = word32ToInt32 (0x8004018F ::Word32)
oLEOBJ_E_NOVERBS :: HRESULT
oLEOBJ_E_NOVERBS = word32ToInt32 (0x80040180 ::Word32)
oLEOBJ_S_CANNOT_DOVERB_NOW :: HRESULT
oLEOBJ_S_CANNOT_DOVERB_NOW = word32ToInt32 (0x00040181 ::Word32)
oLEOBJ_S_FIRST :: HRESULT
oLEOBJ_S_FIRST = word32ToInt32 (0x00040180 ::Word32)
oLEOBJ_S_INVALIDHWND :: HRESULT
oLEOBJ_S_INVALIDHWND = word32ToInt32 (0x00040182 ::Word32)
oLEOBJ_S_INVALIDVERB :: HRESULT
oLEOBJ_S_INVALIDVERB = word32ToInt32 (0x00040180 ::Word32)
oLEOBJ_S_LAST :: HRESULT
oLEOBJ_S_LAST = word32ToInt32 (0x0004018F ::Word32)

oLE_E_ADVF :: HRESULT
oLE_E_ADVF = word32ToInt32 (0x80040001 ::Word32)
oLE_E_ADVISENOTSUPPORTED :: HRESULT
oLE_E_ADVISENOTSUPPORTED = word32ToInt32 (0x80040003 ::Word32)
oLE_E_BLANK :: HRESULT
oLE_E_BLANK = word32ToInt32 (0x80040007 ::Word32)
oLE_E_CANTCONVERT :: HRESULT
oLE_E_CANTCONVERT = word32ToInt32 (0x80040011 ::Word32)
oLE_E_CANT_BINDTOSOURCE :: HRESULT
oLE_E_CANT_BINDTOSOURCE = word32ToInt32 (0x8004000A ::Word32)
oLE_E_CANT_GETMONIKER :: HRESULT
oLE_E_CANT_GETMONIKER = word32ToInt32 (0x80040009 ::Word32)
oLE_E_CLASSDIFF :: HRESULT
oLE_E_CLASSDIFF = word32ToInt32 (0x80040008 ::Word32)
oLE_E_ENUM_NOMORE :: HRESULT
oLE_E_ENUM_NOMORE = word32ToInt32 (0x80040002 ::Word32)
oLE_E_FIRST :: HRESULT
oLE_E_FIRST = word32ToInt32 (0x80040000::Word32)
oLE_E_INVALIDHWND :: HRESULT
oLE_E_INVALIDHWND = word32ToInt32 (0x8004000F ::Word32)
oLE_E_INVALIDRECT :: HRESULT
oLE_E_INVALIDRECT = word32ToInt32 (0x8004000D ::Word32)
oLE_E_LAST :: HRESULT
oLE_E_LAST = word32ToInt32 (0x800400FF::Word32)
oLE_E_NOCACHE :: HRESULT
oLE_E_NOCACHE = word32ToInt32 (0x80040006 ::Word32)
oLE_E_NOCONNECTION :: HRESULT
oLE_E_NOCONNECTION = word32ToInt32 (0x80040004 ::Word32)
oLE_E_NOSTORAGE :: HRESULT
oLE_E_NOSTORAGE = word32ToInt32 (0x80040012 ::Word32)
oLE_E_NOTRUNNING :: HRESULT
oLE_E_NOTRUNNING = word32ToInt32 (0x80040005 ::Word32)
oLE_E_NOT_INPLACEACTIVE :: HRESULT
oLE_E_NOT_INPLACEACTIVE = word32ToInt32 (0x80040010 ::Word32)
oLE_E_OLEVERB :: HRESULT
oLE_E_OLEVERB = word32ToInt32 (0x80040000 ::Word32)
oLE_E_PROMPTSAVECANCELLED :: HRESULT
oLE_E_PROMPTSAVECANCELLED = word32ToInt32 (0x8004000C ::Word32)
oLE_E_STATIC :: HRESULT
oLE_E_STATIC = word32ToInt32 (0x8004000B ::Word32)
oLE_E_WRONGCOMPOBJ :: HRESULT
oLE_E_WRONGCOMPOBJ = word32ToInt32 (0x8004000E ::Word32)
oLE_S_FIRST :: HRESULT
oLE_S_FIRST = word32ToInt32 (0x00040000 ::Word32)
oLE_S_LAST :: HRESULT
oLE_S_LAST = word32ToInt32 (0x000400FF ::Word32)
oLE_S_MAC_CLIPFORMAT :: HRESULT
oLE_S_MAC_CLIPFORMAT = word32ToInt32 (0x00040002 ::Word32)
oLE_S_STATIC :: HRESULT
oLE_S_STATIC = word32ToInt32 (0x00040001 ::Word32)
oLE_S_USEREG :: HRESULT
oLE_S_USEREG = word32ToInt32 (0x00040000 ::Word32)

pERSIST_E_NOTSELFSIZING :: HRESULT
pERSIST_E_NOTSELFSIZING = word32ToInt32 (0x800B000B ::Word32)
pERSIST_E_SIZEDEFINITE :: HRESULT
pERSIST_E_SIZEDEFINITE = word32ToInt32 (0x800B0009 ::Word32)
pERSIST_E_SIZEINDEFINITE :: HRESULT
pERSIST_E_SIZEINDEFINITE = word32ToInt32 (0x800B000A ::Word32)

sTG_E_ABNORMALAPIEXIT :: HRESULT
sTG_E_ABNORMALAPIEXIT = word32ToInt32 (0x800300FA ::Word32)
sTG_E_ACCESSDENIED :: HRESULT
sTG_E_ACCESSDENIED = word32ToInt32 (0x80030005 ::Word32)
sTG_E_BADBASEADDRESS :: HRESULT
sTG_E_BADBASEADDRESS = word32ToInt32 (0x80030110 ::Word32)
sTG_E_CANTSAVE :: HRESULT
sTG_E_CANTSAVE = word32ToInt32 (0x80030103 ::Word32)
sTG_E_DISKISWRITEPROTECTED :: HRESULT
sTG_E_DISKISWRITEPROTECTED = word32ToInt32 (0x80030013 ::Word32)
sTG_E_DOCFILECORRUPT :: HRESULT
sTG_E_DOCFILECORRUPT = word32ToInt32 (0x80030109 ::Word32)
sTG_E_EXTANTMARSHALLINGS :: HRESULT
sTG_E_EXTANTMARSHALLINGS = word32ToInt32 (0x80030108 ::Word32)
sTG_E_FILEALREADYEXISTS :: HRESULT
sTG_E_FILEALREADYEXISTS = word32ToInt32 (0x80030050 ::Word32)
sTG_E_FILENOTFOUND :: HRESULT
sTG_E_FILENOTFOUND = word32ToInt32 (0x80030002 ::Word32)
sTG_E_INCOMPLETE :: HRESULT
sTG_E_INCOMPLETE = word32ToInt32 (0x80030201 ::Word32)
sTG_E_INSUFFICIENTMEMORY :: HRESULT
sTG_E_INSUFFICIENTMEMORY = word32ToInt32 (0x80030008 ::Word32)
sTG_E_INUSE :: HRESULT
sTG_E_INUSE = word32ToInt32 (0x80030100 ::Word32)
sTG_E_INVALIDFLAG :: HRESULT
sTG_E_INVALIDFLAG = word32ToInt32 (0x800300FF ::Word32)
sTG_E_INVALIDFUNCTION :: HRESULT
sTG_E_INVALIDFUNCTION = word32ToInt32 (0x80030001 ::Word32)
sTG_E_INVALIDHANDLE :: HRESULT
sTG_E_INVALIDHANDLE = word32ToInt32 (0x80030006 ::Word32)
sTG_E_INVALIDHEADER :: HRESULT
sTG_E_INVALIDHEADER = word32ToInt32 (0x800300FB ::Word32)
sTG_E_INVALIDNAME :: HRESULT
sTG_E_INVALIDNAME = word32ToInt32 (0x800300FC ::Word32)
sTG_E_INVALIDPARAMETER :: HRESULT
sTG_E_INVALIDPARAMETER = word32ToInt32 (0x80030057 ::Word32)
sTG_E_INVALIDPOINTER :: HRESULT
sTG_E_INVALIDPOINTER = word32ToInt32 (0x80030009 ::Word32)
sTG_E_LOCKVIOLATION :: HRESULT
sTG_E_LOCKVIOLATION = word32ToInt32 (0x80030021 ::Word32)
sTG_E_MEDIUMFULL :: HRESULT
sTG_E_MEDIUMFULL = word32ToInt32 (0x80030070 ::Word32)
sTG_E_NOMOREFILES :: HRESULT
sTG_E_NOMOREFILES = word32ToInt32 (0x80030012 ::Word32)
sTG_E_NOTCURRENT :: HRESULT
sTG_E_NOTCURRENT = word32ToInt32 (0x80030101 ::Word32)
sTG_E_NOTFILEBASEDSTORAGE :: HRESULT
sTG_E_NOTFILEBASEDSTORAGE = word32ToInt32 (0x80030107 ::Word32)
sTG_E_OLDDLL :: HRESULT
sTG_E_OLDDLL = word32ToInt32 (0x80030105 ::Word32)
sTG_E_OLDFORMAT :: HRESULT
sTG_E_OLDFORMAT = word32ToInt32 (0x80030104 ::Word32)
sTG_E_PATHNOTFOUND :: HRESULT
sTG_E_PATHNOTFOUND = word32ToInt32 (0x80030003 ::Word32)
sTG_E_PROPSETMISMATCHED :: HRESULT
sTG_E_PROPSETMISMATCHED = word32ToInt32 (0x800300F0 ::Word32)
sTG_E_READFAULT :: HRESULT
sTG_E_READFAULT = word32ToInt32 (0x8003001E ::Word32)
sTG_E_REVERTED :: HRESULT
sTG_E_REVERTED = word32ToInt32 (0x80030102 ::Word32)
sTG_E_SEEKERROR :: HRESULT
sTG_E_SEEKERROR = word32ToInt32 (0x80030019 ::Word32)
sTG_E_SHAREREQUIRED :: HRESULT
sTG_E_SHAREREQUIRED = word32ToInt32 (0x80030106 ::Word32)
sTG_E_SHAREVIOLATION :: HRESULT
sTG_E_SHAREVIOLATION = word32ToInt32 (0x80030020 ::Word32)
sTG_E_TERMINATED :: HRESULT
sTG_E_TERMINATED = word32ToInt32 (0x80030202 ::Word32)
sTG_E_TOOMANYOPENFILES :: HRESULT
sTG_E_TOOMANYOPENFILES = word32ToInt32 (0x80030004 ::Word32)
sTG_E_UNIMPLEMENTEDFUNCTION :: HRESULT
sTG_E_UNIMPLEMENTEDFUNCTION = word32ToInt32 (0x800300FE ::Word32)
sTG_E_UNKNOWN :: HRESULT
sTG_E_UNKNOWN = word32ToInt32 (0x800300FD ::Word32)
sTG_E_WRITEFAULT :: HRESULT
sTG_E_WRITEFAULT = word32ToInt32 (0x8003001D ::Word32)
sTG_S_BLOCK :: HRESULT
sTG_S_BLOCK = word32ToInt32 (0x00030201 ::Word32)
sTG_S_CANNOTCONSOLIDATE :: HRESULT
sTG_S_CANNOTCONSOLIDATE = word32ToInt32 (0x00030206 ::Word32)
sTG_S_CONSOLIDATIONFAILED :: HRESULT
sTG_S_CONSOLIDATIONFAILED = word32ToInt32 (0x00030205 ::Word32)
sTG_S_CONVERTED :: HRESULT
sTG_S_CONVERTED = word32ToInt32 (0x00030200 ::Word32)
sTG_S_MONITORING :: HRESULT
sTG_S_MONITORING = word32ToInt32 (0x00030203 ::Word32)
sTG_S_MULTIPLEOPENS :: HRESULT
sTG_S_MULTIPLEOPENS = word32ToInt32 (0x00030204 ::Word32)
sTG_S_RETRYNOW :: HRESULT
sTG_S_RETRYNOW = word32ToInt32 (0x00030202 ::Word32)

tYPE_E_AMBIGUOUSNAME :: HRESULT
tYPE_E_AMBIGUOUSNAME = word32ToInt32 (0x8002802C ::Word32)
tYPE_E_BADMODULEKIND :: HRESULT
tYPE_E_BADMODULEKIND = word32ToInt32 (0x800288BD ::Word32)
tYPE_E_BUFFERTOOSMALL :: HRESULT
tYPE_E_BUFFERTOOSMALL = word32ToInt32 (0x80028016 ::Word32)
tYPE_E_CANTCREATETMPFILE :: HRESULT
tYPE_E_CANTCREATETMPFILE = word32ToInt32 (0x80028CA3 ::Word32)
tYPE_E_CANTLOADLIBRARY :: HRESULT
tYPE_E_CANTLOADLIBRARY = word32ToInt32 (0x80029C4A ::Word32)
tYPE_E_CIRCULARTYPE :: HRESULT
tYPE_E_CIRCULARTYPE = word32ToInt32 (0x80029C84 ::Word32)
tYPE_E_DLLFUNCTIONNOTFOUND :: HRESULT
tYPE_E_DLLFUNCTIONNOTFOUND = word32ToInt32 (0x8002802F ::Word32)
tYPE_E_DUPLICATEID :: HRESULT
tYPE_E_DUPLICATEID = word32ToInt32 (0x800288C6 ::Word32)
tYPE_E_ELEMENTNOTFOUND :: HRESULT
tYPE_E_ELEMENTNOTFOUND = word32ToInt32 (0x8002802B ::Word32)
tYPE_E_FIELDNOTFOUND :: HRESULT
tYPE_E_FIELDNOTFOUND = word32ToInt32 (0x80028017 ::Word32)
tYPE_E_INCONSISTENTPROPFUNCS :: HRESULT
tYPE_E_INCONSISTENTPROPFUNCS = word32ToInt32 (0x80029C83 ::Word32)
tYPE_E_INVALIDID :: HRESULT
tYPE_E_INVALIDID = word32ToInt32 (0x800288CF ::Word32)
tYPE_E_INVALIDSTATE :: HRESULT
tYPE_E_INVALIDSTATE = word32ToInt32 (0x80028029 ::Word32)
tYPE_E_INVDATAREAD :: HRESULT
tYPE_E_INVDATAREAD = word32ToInt32 (0x80028018 ::Word32)
tYPE_E_IOERROR :: HRESULT
tYPE_E_IOERROR = word32ToInt32 (0x80028CA2 ::Word32)
tYPE_E_LIBNOTREGISTERED :: HRESULT
tYPE_E_LIBNOTREGISTERED = word32ToInt32 (0x8002801D ::Word32)
tYPE_E_NAMECONFLICT :: HRESULT
tYPE_E_NAMECONFLICT = word32ToInt32 (0x8002802D ::Word32)
tYPE_E_OUTOFBOUNDS :: HRESULT
tYPE_E_OUTOFBOUNDS = word32ToInt32 (0x80028CA1 ::Word32)
tYPE_E_QUALIFIEDNAMEDISALLOWED :: HRESULT
tYPE_E_QUALIFIEDNAMEDISALLOWED = word32ToInt32 (0x80028028 ::Word32)
tYPE_E_REGISTRYACCESS :: HRESULT
tYPE_E_REGISTRYACCESS = word32ToInt32 (0x8002801C ::Word32)
tYPE_E_SIZETOOBIG :: HRESULT
tYPE_E_SIZETOOBIG = word32ToInt32 (0x800288C5 ::Word32)
tYPE_E_TYPEMISMATCH :: HRESULT
tYPE_E_TYPEMISMATCH = word32ToInt32 (0x80028CA0 ::Word32)
tYPE_E_UNDEFINEDTYPE :: HRESULT
tYPE_E_UNDEFINEDTYPE = word32ToInt32 (0x80028027 ::Word32)
tYPE_E_UNKNOWNLCID :: HRESULT
tYPE_E_UNKNOWNLCID = word32ToInt32 (0x8002802E ::Word32)
tYPE_E_UNSUPFORMAT :: HRESULT
tYPE_E_UNSUPFORMAT = word32ToInt32 (0x80028019 ::Word32)
tYPE_E_WRONGTYPEKIND :: HRESULT
tYPE_E_WRONGTYPEKIND = word32ToInt32 (0x8002802A ::Word32)
vIEW_E_DRAW :: HRESULT
vIEW_E_DRAW = word32ToInt32 (0x80040140 ::Word32)
vIEW_E_FIRST :: HRESULT
vIEW_E_FIRST = word32ToInt32 (0x80040140 ::Word32)
vIEW_E_LAST :: HRESULT
vIEW_E_LAST = word32ToInt32 (0x8004014F ::Word32)
vIEW_S_ALREADY_FROZEN :: HRESULT
vIEW_S_ALREADY_FROZEN = word32ToInt32 (0x00040140 ::Word32)
vIEW_S_FIRST :: HRESULT
vIEW_S_FIRST = word32ToInt32 (0x00040140 ::Word32)
vIEW_S_LAST :: HRESULT
vIEW_S_LAST = word32ToInt32 (0x0004014F ::Word32)