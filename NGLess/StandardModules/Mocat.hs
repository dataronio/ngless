{- Copyright 2016 NGLess Authors
 - License: MIT
 -}

{-# LANGUAGE TupleSections, OverloadedStrings #-}

module StandardModules.Mocat
    ( loadModule
    ) where

import qualified Data.Text as T
import System.FilePath.Posix
import System.FilePath.Glob
import Data.String.Utils
import Control.Monad.IO.Class (liftIO)
import Control.Monad
import Control.Applicative
import Data.Maybe
import Data.Default

import Output
import NGLess
import Modules
import Language

dropEnd :: Int -> [a] -> [a]
dropEnd v a = take (length a - v) a -- take of a negative is the empty sequence, which is correct in this case

replaceEnd :: String -> String -> String -> Maybe String
replaceEnd end newEnd str
        | endswith end str = Just (dropEnd (length end) str ++ newEnd)
        | otherwise = Nothing

mocatSamplePaired :: [FilePath] -> NGLessIO [Expression]
mocatSamplePaired matched = do
    let matched1 = filter (\f -> endswith ".1.fq.gz" f || endswith "1.fq.bz2" f) matched
    forM matched1 $ \m1 -> do
        let Just m2 = replaceEnd "1.fq.gz" "2.fq.gz" m1 <|> replaceEnd "1.fq.bz2" "2.fq.bz2" m1
        unless (m2 `elem` matched) $
            throwDataError ("Cannot find match for file: " ++ m1)
        return (FunctionCall (FuncName "paired") (ConstStr . T.pack $ m1) [(Variable "second", ConstStr . T.pack $ m2)] Nothing)


transformMocatLoad :: [(Int, Expression)] -> NGLessIO [(Int, Expression)]
transformMocatLoad script = forM script $ \(lno, e) -> (lno,) <$> mocatToGroup e

mocatToGroup :: Expression -> NGLessIO Expression
mocatToGroup = recursiveTransform mocatToGroup'

mocatToGroup' :: Expression -> NGLessIO Expression
mocatToGroup' (FunctionCall (FuncName "mocat_load_sample") arg kwargs block) = do
    when (isJust block) $
        throwScriptError ("mocat_sample does not take a code block" :: String)
    unless (null  kwargs) $
        throwScriptError ("mocat_sample does not take any keyword arguments" :: String)
    case arg of
        ConstStr samplename -> do
            outputListLno' TraceOutput ["Executing mocat_load_sample transform"]
            let basedir = T.unpack samplename
            matched <- liftIO $ liftM2 (++)
                            (namesMatching (basedir </> "*.fq.gz"))
                            (namesMatching (basedir </> "*.fq.bz2"))
            let matched1 = filter (\f -> endswith ".1.fq.gz" f || endswith "1.fq.bz2" f) matched
            args <- ListExpression <$> if null matched1
                    then return [FunctionCall (FuncName "fastq") (ConstStr . T.pack $ f) [] Nothing | f <- matched]
                    else mocatSamplePaired matched
            return (FunctionCall (FuncName "group") args [(Variable "name", arg)] Nothing)
        _ -> throwScriptError ("mocat_sample got wrong argument, expected a string, got " ++ show arg)
mocatToGroup' e = return e


mocatLoadSample = Function
    { funcName = FuncName "mocat_load_sample"
    , funcArgType = Just NGLString
    , funcRetType = NGLReadSet
    , funcKwArgs = []
    , funcAllowsAutoComprehension = False
    }


loadModule :: T.Text -> NGLessIO Module
loadModule _ =
        return def
        { modInfo = ModInfo "stdlib.mocat" "0.0"
        , modCitation = Just citation
        , modTransform = transformMocatLoad
        , modFunctions = [mocatLoadSample]
        }
    where
        citation = T.concat
            ["Kultima JR, Sunagawa S, Li J, Chen W, Chen H, Mende DR, et al. (2012)\n"
            ,"MOCAT: A Metagenomics Assembly and Gene Prediction Toolkit.\n"
            ,"PLoS ONE 7(10): e47656. doi:10.1371/journal.pone.0047656"]