{- Copyright 2013-2015 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE DeriveDataTypeable, OverloadedStrings #-}
module Main
    ( main
    ) where

import Interpret
import Validation
import ValidationNotPure
import Language
import Types
import Parse
import Configuration
import ReferenceDatabases
import Output

import Data.Maybe
import Control.Monad
import Control.Applicative
import Control.Concurrent
import System.Console.CmdArgs
import System.FilePath.Posix
import System.Directory
import System.IO (stderr, hPutStrLn)
import System.Console.ANSI
import System.Exit (exitSuccess, exitFailure)


import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.ByteString as B


data NGLess =
        DefaultMode
              { debug_mode :: String
              , input :: String
              , script :: Maybe String
              , print_last :: Bool
              , trace_flag :: Bool
              , n_threads :: Int
              , output_directory :: Maybe FilePath
              , temporary_directory :: Maybe FilePath
              , keep_temporary_files :: Bool
              }
        | InstallGenMode
              { input :: String}
           deriving (Eq, Show, Data, Typeable)

ngless = DefaultMode
        { debug_mode = "ngless"
        , input = "-" &= argPos 0 &= opt ("-" :: String)
        , script = Nothing &= name "e"
        , trace_flag = False &= name "trace"
        , print_last = False &= name "p"
        , n_threads = 1 &= name "n"
        , output_directory = Nothing &= name "o"
        , temporary_directory = Nothing &= name "t"
        , keep_temporary_files = False
        }
        &= details  [ "Example:" , "ngless script.ngl" ]


installargs = InstallGenMode
        { input = "Reference" &= argPos 0
        }
        &= name "--install-reference-data"
        &= details  [ "Example:" , "(sudo) ngless --install-reference-data sacCer3" ]


wrapPrint (Script v sc) = wrap sc >>= Right . Script v
    where
        wrap [] = Right []
        wrap [(lno,e)]
            | wrapable e = Right [(lno,addPrint e)]
            | otherwise = Left "Cannot add write() statement at the end of script (the script cannot terminate with a print/write call)"
        wrap (e:es) = wrap es >>= Right . (e:)
        addPrint e = FunctionCall Fwrite e [(Variable "ofile", BuiltinConstant (Variable "STDOUT"))] Nothing

        wrapable (FunctionCall f _ _ _)
            | f `elem` [Fprint, Fwrite] = False
        wrapable _ = True

rightOrDie :: (Show e) => Either e a -> IO a
rightOrDie (Left err) = fatalError (show err)
rightOrDie (Right v) = return v

fatalError :: String -> IO b
fatalError err = do
    let st = setSGRCode [SetColor Foreground Dull Red]
    hPutStrLn stderr (st ++ "FATAL ERROR: "++err)
    exitFailure

whenStrictlyNormal act = do
    v <- getVerbosity
    when (v == Normal) act

optsExec :: NGLess -> IO ()
optsExec opts@DefaultMode{} = do
    let fname = input opts
    let reqversion = isNothing $ script opts
    setNumCapabilities (n_threads opts)
    case (output_directory opts, fname) of
        (Nothing,"") -> setOutputDirectory "STDIN.output_ngless"
        (Nothing,_) -> setOutputDirectory (fname ++ ".output_ngless")
        (Just odir, _) -> setOutputDirectory odir
    setTemporaryDirectory (temporary_directory opts)
    setKeepTemporaryFiles (keep_temporary_files opts)
    setTraceFlag (trace_flag opts)
    odir <- outputDirectory
    createDirectoryIfMissing False odir
    --Note that the input for ngless is always UTF-8.
    --Always. This means that we cannot use T.readFile
    --which is locale aware.
    --We also assume that the text file is quite small and, therefore, loading
    --it in to memory is not resource intensive.
    engltext <- case script opts of
        Just s -> return . Right . T.pack $ s
        _ -> T.decodeUtf8' <$> (if fname == "-" then B.getContents else B.readFile fname)
    ngltext <- rightOrDie engltext
    let maybe_add_print = (if print_last opts then wrapPrint else Right)
    let parsed = parsengless fname reqversion ngltext >>= maybe_add_print >>= checktypes >>= validate
    sc <- rightOrDie parsed
    when (debug_mode opts == "ast") $ do
        forM_ (nglBody sc) $ \(lno,e) ->
            putStrLn ((if lno < 10 then " " else "")++show lno++": "++show e)
        exitSuccess

    when (uses_STDOUT `any` [e | (_,e) <- nglBody sc]) $
        whenStrictlyNormal (setVerbosity Quiet)
    outputLno' DebugOutput "Validating script..."
    errs <- validate_io sc
    when (isJust errs) $
        rightOrDie (Left . fromJust $ errs)
    outputLno' InfoOutput "Script OK. Starting interpretation..."
    interpret fname ngltext (nglBody sc)
    writeOutput (odir </> "output.js") fname ngltext


-- if user uses the flag -i he will install a Reference Genome to all users
optsExec (InstallGenMode ref)
    | isDefaultReference ref = void $ installData Nothing ref
    | otherwise =
        error (concat ["Reference ", ref, " is not a known reference."])

getModes :: Mode (CmdArgs NGLess)
getModes = cmdArgsMode $ modes [ngless &= auto, installargs]
    &= verbosity
    &= summary sumtext
    &= help "ngless implement the NGLess language"
    where sumtext = concat ["ngless v", versionStr, "(C) NGLess Authors 2013-2015"]

main = cmdArgsRun getModes >>= optsExec
